//
//  MemoryIndexTests.swift
//  OraTests
//
//  Tests for hybrid memory retrieval over MEMORY.md and session summaries.
//

import XCTest
@testable import Ora

struct StubEmbeddingService: EmbeddingServicing {
    var vectorDimension: Int { 16 }

    private static let tokenDimensions: [String: Int] = [
        "atlas": 0,
        "migration": 1,
        "phoenix": 2,
        "guardrail": 3,
        "budget": 4,
        "variance": 5,
        "review": 6,
        "food": 7,
        "cuisine": 7,
        "spicy": 8,
        "like": 9,
        "enjoy": 9,
        "prefer": 9,
        "meeting": 10,
        "project": 11,
        "decision": 12,
        "weekly": 13,
        "summary": 14,
        "general": 15
    ]

    func embed(text: String) async throws -> [Float] {
        return Self.makeVector(from: text, dimension: self.vectorDimension)
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        return texts.map { text in
            return Self.makeVector(from: text, dimension: self.vectorDimension)
        }
    }

    private static func makeVector(from text: String, dimension: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        let tokens = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        for token in tokens {
            if let index = self.tokenDimensions[token] {
                vector[index] += 1
            }

            if token == "enjoy" || token == "enjoying" {
                vector[9] += 1
            }

            if token == "meal" {
                vector[7] += 1
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
}

final class MemoryIndexTests: XCTestCase {

    // MARK: - Properties

    private var temporaryDirectoryURL: URL!
    private var documentsDirectoryURL: URL!
    private var memoryFileManager: MemoryFileManager!
    private var memoryIndex: MemoryIndex!

    // MARK: - Setup

    override func setUpWithError() throws {
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.documentsDirectoryURL = self.temporaryDirectoryURL
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: self.documentsDirectoryURL, withIntermediateDirectories: true)

        self.memoryFileManager = MemoryFileManager(documentsDirectory: self.documentsDirectoryURL)
        try self.memoryFileManager.ensureMemoryStructureExists()
        self.memoryIndex = MemoryIndex(
            documentsDirectory: self.documentsDirectoryURL,
            embeddingService: StubEmbeddingService()
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL = self.temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        self.memoryIndex = nil
        self.memoryFileManager = nil
        self.documentsDirectoryURL = nil
        self.temporaryDirectoryURL = nil
    }

    // MARK: - Tests

    func test_index_memoryAndSummaries_rebuildAndSearch_returnsRelevantChunksWithMetadata() async throws {
        // Given
        let memoryContent = """
# Ora Memory

## Projects
- Atlas migration depends on Phoenix gateway guardrail checklist.
"""
        try memoryContent.write(to: self.memoryFileManager.memoryFileURL, atomically: true, encoding: .utf8)

        let sessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let summaryContent = """
# Session Summary

## TL;DR
Aligned on budget variance review.

## Decisions & Commitments
1. Decision: Track budget variance weekly.
"""
        try self.memoryFileManager.writeSummary(sessionId: sessionID, content: summaryContent)

        await self.memoryIndex.rebuild()

        // When
        let summaryMatches = await self.memoryIndex.search(query: "budget variance review", limit: 5)
        let memoryMatches = await self.memoryIndex.search(query: "phoenix guardrail", limit: 5)

        // Then
        XCTAssertFalse(summaryMatches.isEmpty)
        XCTAssertFalse(memoryMatches.isEmpty)

        let summaryTopResult = try XCTUnwrap(summaryMatches.first)
        XCTAssertEqual(summaryTopResult.documentType, .summary)
        XCTAssertEqual(summaryTopResult.sessionID, sessionID)
        XCTAssertEqual(summaryTopResult.sectionName, "TL;DR")

        let memoryTopResult = try XCTUnwrap(memoryMatches.first)
        XCTAssertEqual(memoryTopResult.documentType, .memory)
        XCTAssertNil(memoryTopResult.sessionID)
        XCTAssertEqual(memoryTopResult.sectionName, "Projects")
    }

    func test_search_queryWithoutMatches_returnsEmptyResult() async throws {
        // Given
        let memoryContent = """
# Ora Memory

## Preferences
- User prefers concise meeting notes.
"""
        try memoryContent.write(to: self.memoryFileManager.memoryFileURL, atomically: true, encoding: .utf8)
        await self.memoryIndex.rebuild()

        // When
        let matches = await self.memoryIndex.search(query: "galaxy nebula astrophotography", limit: 7)

        // Then
        XCTAssertTrue(matches.isEmpty)
    }

    func test_search_relevanceDifference_ranksMoreRelevantChunkFirst() async throws {
        // Given
        let memoryContent = """
# Ora Memory

## Projects
- Phoenix rollout requires strict guardrail checklist and release gates.
- Phoenix rollout update.
"""
        try memoryContent.write(to: self.memoryFileManager.memoryFileURL, atomically: true, encoding: .utf8)
        await self.memoryIndex.rebuild()

        // When
        let matches = await self.memoryIndex.search(query: "phoenix guardrail checklist", limit: 5)

        // Then
        XCTAssertGreaterThanOrEqual(matches.count, 2)
        let first = try XCTUnwrap(matches.first)
        XCTAssertTrue(first.content.contains("strict guardrail checklist"))
        let second = try XCTUnwrap(matches.dropFirst().first)
        XCTAssertGreaterThan(first.score, second.score)
    }

    func test_search_paraphrasedQuery_returnsSemanticallyRelevantChunk() async throws {
        // Given
        let memoryContent = """
# Ora Memory

## Preferences
- User likes spicy cuisine.
"""
        try memoryContent.write(to: self.memoryFileManager.memoryFileURL, atomically: true, encoding: .utf8)
        await self.memoryIndex.rebuild()

        // When
        let matches = await self.memoryIndex.search(query: "what kind of food do I enjoy", limit: 5)

        // Then
        let top = try XCTUnwrap(matches.first)
        XCTAssertTrue(top.content.contains("likes spicy cuisine"))
    }
}
