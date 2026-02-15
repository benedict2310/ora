//
//  EmbeddingServiceTests.swift
//  OraTests
//
//  Tests for local embedding generation used by memory retrieval.
//

import XCTest
@testable import Ora

final class EmbeddingServiceTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            self.lock.lock()
            self.value += 1
            self.lock.unlock()
        }

        func currentValue() -> Int {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.value
        }
    }

    private static func makeTestVectors(texts: [String], dimension: Int) -> [[Float]] {
        return texts.map { text in
            return self.makeTestVector(text: text, dimension: dimension)
        }
    }

    private static func makeTestVector(text: String, dimension: Int) -> [Float] {
        guard dimension > 0 else {
            return []
        }

        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        var vector = [Float](repeating: 0, count: dimension)
        let tokens = normalized.split(separator: " ").map(String.init)

        for token in tokens {
            switch token {
            case "food", "cuisine", "meal":
                vector[min(0, dimension - 1)] += 1
            case "spicy":
                vector[min(1, dimension - 1)] += 1
            case "like", "likes", "enjoy", "enjoying", "prefer", "prefers":
                vector[min(2, dimension - 1)] += 1
            case "gateway", "rollout", "checklist", "release", "gates":
                vector[min(3, dimension - 1)] += 1
            default:
                break
            }
        }

        let squaredNorm = vector.reduce(Float.zero) { partial, value in
            return partial + (value * value)
        }

        guard squaredNorm > 0 else {
            return vector
        }

        let scale = 1 / sqrt(squaredNorm)
        return vector.map { value in
            return value * scale
        }
    }

    private static var isCI: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CI"] != nil || env["GITHUB_ACTIONS"] != nil
    }

    private static func isModelAvailabilityError(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("no such file")
            || description.contains("not found")
            || description.contains("doesn't exist")
            || description.contains("can't connect")
            || description.contains("connection")
            || description.contains("resolve host")
            || description.contains("network")
            || description.contains("timed out")
            || description.contains("offline")
            || description.contains("download")
            || description.contains("keynotfound")
    }

    func test_embed_sampleText_returnsNonZeroVectorWithExpectedDimension() async throws {
        // Given
        let service = EmbeddingService(
            configuration: .init(vectorDimension: 128, gpuCacheLimitBytes: 8 * 1024 * 1024),
            batchEmbedder: { texts in
                return Self.makeTestVectors(texts: texts, dimension: 128)
            }
        )

        // When
        let vector = try await service.embed(text: "I like spicy food")

        // Then
        XCTAssertEqual(vector.count, 128)
        XCTAssertTrue(vector.contains { value in
            return abs(value) > 0.0001
        })
    }

    func test_embed_semanticParaphrase_scoresHigherThanUnrelatedText() async throws {
        // Given
        let service = EmbeddingService(
            configuration: .init(vectorDimension: 256, gpuCacheLimitBytes: 8 * 1024 * 1024),
            batchEmbedder: { texts in
                return Self.makeTestVectors(texts: texts, dimension: 256)
            }
        )

        // When
        let query = try await service.embed(text: "What kind of food do I enjoy?")
        let paraphrase = try await service.embed(text: "I like spicy food")
        let unrelated = try await service.embed(text: "Gateway rollout checklist and release gates")

        let paraphraseScore = HybridScorer.cosineSimilarity(query, paraphrase)
        let unrelatedScore = HybridScorer.cosineSimilarity(query, unrelated)

        // Then
        XCTAssertGreaterThan(paraphraseScore, unrelatedScore)
    }

    func test_embed_textBatch_clearsGPUCacheAfterEachBatch() async throws {
        // Given
        let limitCounter = Counter()
        let clearCounter = Counter()
        let service = EmbeddingService(
            configuration: .init(vectorDimension: 64, gpuCacheLimitBytes: 4 * 1024 * 1024),
            gpuCacheLimiter: { _ in
                limitCounter.increment()
            },
            gpuCacheClearer: {
                clearCounter.increment()
            },
            batchEmbedder: { texts in
                return Self.makeTestVectors(texts: texts, dimension: 64)
            }
        )

        // When
        _ = try await service.embed(texts: ["I like tea", "I enjoy coffee"])
        _ = try await service.embed(texts: ["I prefer sparkling water"])

        // Then
        XCTAssertEqual(limitCounter.currentValue(), 1)
        XCTAssertEqual(clearCounter.currentValue(), 2)
    }

    func test_embed_realModelPath_generatesVectorWhenModelAvailable() async throws {
        try XCTSkipIf(
            Self.isCI,
            "MLXEmbedders crashes on CI runners without Metal GPU support"
        )

        // Given
        let service = EmbeddingService(
            configuration: .init(
                vectorDimension: 384,
                gpuCacheLimitBytes: 64 * 1024 * 1024,
                modelIdentifier: "BAAI/bge-small-en-v1.5",
                batchSize: 2
            )
        )

        // When
        let vectors: [[Float]]
        do {
            vectors = try await service.embed(
                texts: [
                    "I like spicy food.",
                    "What kind of cuisine do I enjoy?"
                ]
            )
        } catch {
            if Self.isModelAvailabilityError(error) {
                throw XCTSkip("Embedding model unavailable for integration path test: \(error.localizedDescription)")
            }
            throw error
        }

        // Then
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0].count, 384)
        XCTAssertEqual(vectors[1].count, 384)
        XCTAssertTrue(vectors[0].contains { abs($0) > 0.0001 })
        XCTAssertTrue(vectors[1].contains { abs($0) > 0.0001 })
    }
}
