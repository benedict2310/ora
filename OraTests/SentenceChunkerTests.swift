//
//  SentenceChunkerTests.swift
//  OraTests
//
//  Tests for SentenceChunker
//

import XCTest
@testable import Ora

final class SentenceChunkerTests: XCTestCase {

    func test_chunkerExtractsSentencesFromStream() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Hello there.")
            continuation.yield(" How are")
            continuation.yield(" you?")
            continuation.finish()
        }

        let chunker = SentenceChunker(minSentenceLength: 5, maxChunkLength: 200)
        let sentenceStream = chunker.chunk(tokens: stream)

        var results: [String] = []
        for try await sentence in sentenceStream {
            results.append(sentence)
        }

        XCTAssertEqual(results, ["Hello there.", "How are you?"])
    }

    func test_chunkerFlushesRemainingTextAtEnd() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("This is incomplete")
            continuation.finish()
        }

        let chunker = SentenceChunker(minSentenceLength: 5, maxChunkLength: 200)
        let sentenceStream = chunker.chunk(tokens: stream)

        var results: [String] = []
        for try await sentence in sentenceStream {
            results.append(sentence)
        }

        XCTAssertEqual(results, ["This is incomplete"])
    }

    func test_chunkerSplitsOversizedText() {
        var chunker = SentenceChunker(minSentenceLength: 1, maxChunkLength: 20)
        let longToken = String(repeating: "a", count: 55)

        var results = chunker.consume(longToken)
        results.append(contentsOf: chunker.finalize())

        XCTAssertTrue(results.count > 1)
        XCTAssertTrue(results.allSatisfy { $0.count <= 20 })
    }

    func test_chunkerCombinesShortSentences() {
        var chunker = SentenceChunker(minSentenceLength: 8, maxChunkLength: 200)

        let first = chunker.consume("Hi.")
        XCTAssertTrue(first.isEmpty)

        let second = chunker.consume(" This is longer.")
        let remaining = chunker.finalize()

        let combined = second + remaining
        XCTAssertEqual(combined, ["Hi. This is longer."])
    }
}
