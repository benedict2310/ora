//
//  MemoryIndexTests.swift
//  OraTests
//
//  Tests for keyword retrieval index over MEMORY.md and session summaries.
//

import XCTest
@testable import Ora

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
        self.memoryIndex = MemoryIndex(documentsDirectory: self.documentsDirectoryURL)
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
        XCTAssertTrue(matches[0].content.contains("strict guardrail checklist"))
        XCTAssertGreaterThan(matches[0].score, matches[1].score)
    }
}
