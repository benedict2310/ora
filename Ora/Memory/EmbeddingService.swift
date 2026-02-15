//
//  EmbeddingService.swift
//  Ora
//
//  Local semantic embedding service used by memory retrieval.
//

import Foundation
import MLX
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

        static let `default` = Configuration(
            vectorDimension: 384,
            gpuCacheLimitBytes: 512 * 1024 * 1024
        )
    }

    typealias GPUCacheLimiter = @Sendable (Int) -> Void
    typealias GPUCacheClearer = @Sendable () -> Void

    // MARK: - Singleton

    static let shared = EmbeddingService()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "memory")
    private let configuration: Configuration
    private let gpuCacheLimiter: GPUCacheLimiter
    private let gpuCacheClearer: GPUCacheClearer
    nonisolated let vectorDimension: Int
    private var isPrepared = false

    // MARK: - Initialization

    init(
        configuration: Configuration = .default,
        gpuCacheLimiter: @escaping GPUCacheLimiter = { bytes in
            GPU.set(cacheLimit: bytes)
        },
        gpuCacheClearer: @escaping GPUCacheClearer = {
            GPU.clearCache()
        }
    ) {
        self.configuration = configuration
        self.gpuCacheLimiter = gpuCacheLimiter
        self.gpuCacheClearer = gpuCacheClearer
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

        self.prepareIfNeeded()
        defer {
            self.gpuCacheClearer()
        }

        return texts.map { text in
            return Self.makeVector(
                from: text,
                dimension: self.configuration.vectorDimension
            )
        }
    }

    // MARK: - Model Lifecycle

    private func prepareIfNeeded() {
        guard !self.isPrepared else {
            return
        }

        self.gpuCacheLimiter(self.configuration.gpuCacheLimitBytes)
        self.isPrepared = true
        self.logger.info("Embedding service prepared with vector dimension \(self.configuration.vectorDimension)")
    }

    // MARK: - Vectorization

    private static func makeVector(from text: String, dimension: Int) -> [Float] {
        guard dimension > 0 else {
            return []
        }

        let tokens = Self.extractSemanticTokens(from: text)
        guard !tokens.isEmpty else {
            return [Float](repeating: 0, count: dimension)
        }

        var vector = [Float](repeating: 0, count: dimension)

        for token in tokens {
            Self.accumulate(feature: "tok:\(token)", weight: 1.0, vector: &vector)
        }

        if tokens.count > 1 {
            for index in 0..<(tokens.count - 1) {
                let bigram = "\(tokens[index])_\(tokens[index + 1])"
                Self.accumulate(feature: "big:\(bigram)", weight: 0.75, vector: &vector)
            }
        }

        for token in tokens {
            let trigrams = Self.characterTrigrams(token)
            for trigram in trigrams {
                Self.accumulate(feature: "tri:\(trigram)", weight: 0.4, vector: &vector)
            }
        }

        let squaredSum = vector.reduce(Float.zero) { partial, value in
            return partial + (value * value)
        }

        guard squaredSum > 0 else {
            return vector
        }

        let inverseNorm = 1 / sqrt(squaredSum)
        for index in vector.indices {
            vector[index] *= inverseNorm
        }

        return vector
    }

    private static func accumulate(feature: String, weight: Float, vector: inout [Float]) {
        let dimension = UInt64(vector.count)
        guard dimension > 0 else {
            return
        }

        let hash = Self.fnv1a64("idx|\(feature)")
        let signHash = Self.fnv1a64("sign|\(feature)")
        let index = Int(hash % dimension)
        let sign: Float = (signHash & 1) == 0 ? 1.0 : -1.0
        vector[index] += weight * sign
    }

    private static func extractSemanticTokens(from text: String) -> [String] {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return []
        }

        var output: [String] = []
        for token in normalized.split(separator: " ").map(String.init) {
            guard !token.isEmpty else {
                continue
            }

            let stemmed = Self.lightStem(token)
            if !stemmed.isEmpty {
                output.append(stemmed)
            }

            if let mapped = Self.semanticMap[stemmed] {
                output.append(mapped)
            }
        }

        return output
    }

    private static func lightStem(_ token: String) -> String {
        guard token.count >= 4 else {
            return token
        }

        if token.hasSuffix("ing") {
            return String(token.dropLast(3))
        }

        if token.hasSuffix("ed") {
            return String(token.dropLast(2))
        }

        if token.hasSuffix("es") {
            return String(token.dropLast(2))
        }

        if token.hasSuffix("s") {
            return String(token.dropLast())
        }

        return token
    }

    private static func characterTrigrams(_ token: String) -> [String] {
        guard token.count >= 3 else {
            return [token]
        }

        let characters = Array(token)
        var trigrams: [String] = []
        trigrams.reserveCapacity(max(1, characters.count - 2))

        for index in 0...(characters.count - 3) {
            let trigram = String(characters[index...index + 2])
            trigrams.append(trigram)
        }

        return trigrams
    }

    private static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }

        return hash
    }

    // MARK: - Semantic Mapping

    private static let semanticMap: [String: String] = [
        "enjoy": "like",
        "lik": "like",
        "favorite": "prefer",
        "favourite": "prefer",
        "pref": "prefer",
        "meal": "food",
        "cuisine": "food",
        "snack": "food",
        "work": "project",
        "task": "project",
        "objective": "goal",
        "aim": "goal"
    ]
}
