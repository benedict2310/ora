//
//  EmbeddingService.swift
//  Ora
//
//  Local semantic embedding service used by memory retrieval.
//

import Foundation
import MLX
import MLXEmbedders
import os

protocol EmbeddingServicing: Sendable {
    var vectorDimension: Int { get }
    func embed(text: String) async throws -> [Float]
    func embed(texts: [String]) async throws -> [[Float]]
}

actor EmbeddingService: EmbeddingServicing {

    // MARK: - Types

    struct Configuration: Sendable, Equatable {
        let vectorDimension: Int
        let gpuCacheLimitBytes: Int
        let modelIdentifier: String
        let batchSize: Int

        init(
            vectorDimension: Int = 384,
            gpuCacheLimitBytes: Int = 512 * 1024 * 1024,
            modelIdentifier: String = "BAAI/bge-small-en-v1.5",
            batchSize: Int = 16
        ) {
            self.vectorDimension = vectorDimension
            self.gpuCacheLimitBytes = gpuCacheLimitBytes
            self.modelIdentifier = modelIdentifier
            self.batchSize = batchSize
        }

        static let `default` = Configuration()
    }

    enum EmbeddingServiceError: LocalizedError {
        case modelUnavailable
        case outputCountMismatch(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "Embedding model is not loaded."
            case .outputCountMismatch(let expected, let actual):
                return "Embedding output count mismatch. Expected \(expected), got \(actual)."
            }
        }
    }

    typealias GPUCacheLimiter = @Sendable (Int) -> Void
    typealias GPUCacheClearer = @Sendable () -> Void
    typealias BatchEmbedder = @Sendable ([String]) async throws -> [[Float]]

    // MARK: - Singleton

    static let shared = EmbeddingService()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "memory")
    private let configuration: Configuration
    private let gpuCacheLimiter: GPUCacheLimiter
    private let gpuCacheClearer: GPUCacheClearer
    private let batchEmbedder: BatchEmbedder?
    nonisolated let vectorDimension: Int
    private var isPrepared = false
    private var modelContainer: MLXEmbedders.ModelContainer?

    // MARK: - Initialization

    init(
        configuration: Configuration = .default,
        gpuCacheLimiter: @escaping GPUCacheLimiter = { bytes in
            GPU.set(cacheLimit: bytes)
        },
        gpuCacheClearer: @escaping GPUCacheClearer = {
            GPU.clearCache()
        },
        batchEmbedder: BatchEmbedder? = nil
    ) {
        self.configuration = configuration
        self.gpuCacheLimiter = gpuCacheLimiter
        self.gpuCacheClearer = gpuCacheClearer
        self.batchEmbedder = batchEmbedder
        self.vectorDimension = configuration.vectorDimension
    }

    // MARK: - Public API

    func embed(text: String) async throws -> [Float] {
        guard let vector = try await self.embed(texts: [text]).first else {
            return []
        }
        return vector
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else {
            return []
        }

        try await self.prepareIfNeeded()
        defer {
            self.gpuCacheClearer()
        }

        var output: [[Float]] = []
        output.reserveCapacity(texts.count)

        let batchSize = max(1, self.configuration.batchSize)
        for startIndex in stride(from: 0, to: texts.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, texts.count)
            let batchTexts = Array(texts[startIndex..<endIndex])

            let batchVectors: [[Float]]
            if let batchEmbedder = self.batchEmbedder {
                batchVectors = try await batchEmbedder(batchTexts)
            } else {
                guard let modelContainer = self.modelContainer else {
                    throw EmbeddingServiceError.modelUnavailable
                }
                batchVectors = try await self.embedBatchWithModel(
                    texts: batchTexts,
                    modelContainer: modelContainer
                )
            }

            guard batchVectors.count == batchTexts.count else {
                throw EmbeddingServiceError.outputCountMismatch(
                    expected: batchTexts.count,
                    actual: batchVectors.count
                )
            }

            for vector in batchVectors {
                output.append(
                    Self.fitVector(
                        vector,
                        to: self.configuration.vectorDimension
                    )
                )
            }
        }

        return output
    }

    // MARK: - Model Lifecycle

    private func prepareIfNeeded() async throws {
        guard !self.isPrepared else {
            return
        }

        self.gpuCacheLimiter(self.configuration.gpuCacheLimitBytes)
        if self.batchEmbedder == nil {
            self.modelContainer = try await self.prepareModelContainer()
        }
        self.isPrepared = true
        self.logger.info(
            "Embedding service prepared with model '\(self.configuration.modelIdentifier)' and vector dimension \(self.configuration.vectorDimension)"
        )
    }

    private func prepareModelContainer() async throws -> MLXEmbedders.ModelContainer {
        let modelConfiguration = MLXEmbedders.ModelConfiguration(
            id: self.configuration.modelIdentifier
        )

        return try await MLXEmbedders.loadModelContainer(
            configuration: modelConfiguration
        )
    }

    private func embedBatchWithModel(
        texts: [String],
        modelContainer: MLXEmbedders.ModelContainer
    ) async throws -> [[Float]] {
        return try await MLXMetalGate.shared.withExclusiveAccess {
            return await modelContainer.perform { model, tokenizer, pooling in
                let encodedInputs = texts.map { text in
                    return tokenizer.encode(text: text, addSpecialTokens: true)
                }

                let maxLength = max(
                    encodedInputs.reduce(0) { partial, tokens in
                        return max(partial, tokens.count)
                    },
                    1
                )
                let eosTokenID = tokenizer.eosTokenId ?? 0

                let padded = MLX.stacked(
                    encodedInputs.map { tokens in
                        let paddedTokens = tokens + Array(
                            repeating: eosTokenID,
                            count: maxLength - tokens.count
                        )
                        return MLXArray(paddedTokens)
                    },
                    axis: 0
                )

                let mask = (padded .!= eosTokenID)
                let tokenTypeIDs = MLXArray.zeros(like: padded)
                let modelOutput = model(
                    padded,
                    positionIds: nil,
                    tokenTypeIds: tokenTypeIDs,
                    attentionMask: mask
                )

                let pooled = pooling(
                    modelOutput,
                    mask: mask,
                    normalize: true,
                    applyLayerNorm: true
                )

                eval(pooled)

                Stream.gpu.synchronize()

                return pooled.map { row in
                    return row.asArray(Float.self)
                }
            }
        }
    }

    // MARK: - Vector Utilities

    private static func fitVector(_ vector: [Float], to dimension: Int) -> [Float] {
        guard dimension > 0 else {
            return []
        }

        if vector.count == dimension {
            return vector
        }

        if vector.count > dimension {
            return Array(vector.prefix(dimension))
        }

        return vector + Array(repeating: 0, count: dimension - vector.count)
    }
}
