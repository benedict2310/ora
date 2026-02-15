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

    func test_embed_sampleText_returnsNonZeroVectorWithExpectedDimension() async throws {
        // Given
        let service = EmbeddingService(
            configuration: .init(vectorDimension: 128, gpuCacheLimitBytes: 8 * 1024 * 1024)
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
            configuration: .init(vectorDimension: 256, gpuCacheLimitBytes: 8 * 1024 * 1024)
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
            }
        )

        // When
        _ = try await service.embed(texts: ["I like tea", "I enjoy coffee"])
        _ = try await service.embed(texts: ["I prefer sparkling water"])

        // Then
        XCTAssertEqual(limitCounter.currentValue(), 1)
        XCTAssertEqual(clearCounter.currentValue(), 2)
    }
}
