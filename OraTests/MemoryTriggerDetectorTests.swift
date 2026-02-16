//
//  MemoryTriggerDetectorTests.swift
//  OraTests
//
//  Tests for memory trigger detection signals and latency.
//

import XCTest
@testable import Ora

final class MemoryTriggerDetectorTests: XCTestCase {

    // MARK: - Properties

    private var temporaryDirectoryURL: URL!

    // MARK: - Setup

    override func setUpWithError() throws {
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL = self.temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        self.temporaryDirectoryURL = nil
    }

    // MARK: - Tests

    func test_detect_linguisticTriggerPhrase_returnsTriggeredResult() throws {
        // Given
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Preferences\n")
        let userText = "Remember my preference for morning meetings."

        // When
        let result = detector.detect(userText: userText)

        // Then
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .linguistic)
        XCTAssertGreaterThan(result.confidence, 0.85)
    }

    func test_detect_taskFramingPhrase_returnsTriggeredResult() throws {
        // Given
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Projects\n")
        let userText = "Can you list the next steps for this plan?"

        // When
        let result = detector.detect(userText: userText)

        // Then
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .taskFraming)
        XCTAssertGreaterThan(result.confidence, 0.75)
    }

    func test_detect_entityOverlapWithMemoryEntries_returnsEntityOverlapTrigger() throws {
        // Given
        let memoryContent = """
# Ora Memory

## Projects
- [fact] Atlas migration depends on the Phoenix rollout.
"""
        let detector = try self.makeDetector(memoryContent: memoryContent)
        let userText = "Any update on the Atlas migration timeline?"

        // When
        let result = detector.detect(userText: userText)

        // Then
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .entityOverlap)
        XCTAssertTrue(result.matchedSignals.contains("atlas"))
    }

    func test_detect_remindMe_triggersLinguistic() throws {
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Preferences\n")
        let result = detector.detect(userText: "Can you remind me what those meetings were about?")
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .linguistic)
    }

    func test_detect_previousConversation_triggersLinguistic() throws {
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Preferences\n")
        let result = detector.detect(userText: "Check if you know anything from our previous conversation")
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .linguistic)
    }

    func test_detect_youMentioned_triggersLinguistic() throws {
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Preferences\n")
        let result = detector.detect(userText: "You mentioned something about a deadline last week")
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .linguistic)
    }

    func test_detect_lastConversation_triggersLinguistic() throws {
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Preferences\n")
        let result = detector.detect(userText: "Let's continue our last conversation, what was that about?")
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .linguistic)
    }

    func test_detect_continueOur_triggersLinguistic() throws {
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Preferences\n")
        let result = detector.detect(userText: "Continue our discussion from this morning")
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .linguistic)
    }

    func test_detect_simpleQuestionWithoutSignals_returnsNoTrigger() throws {
        // Given
        let detector = try self.makeDetector(memoryContent: "# Ora Memory\n\n## Preferences\n")
        let userText = "What's the weather in Austin today?"

        // When
        let result = detector.detect(userText: userText)

        // Then
        XCTAssertFalse(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .none)
        XCTAssertEqual(result.confidence, 0.0)
    }

    func test_detect_cachedIndex_averageLatency_isUnderFiveMilliseconds() throws {
        // Given
        let memoryContent = """
# Ora Memory

## Projects
- [fact] Atlas migration timeline is tracked with QA and release ops.
- [fact] Phoenix API gateway owns rollout and guardrail checks.
- [preference] Keep deployment notes in concise bullet format.
"""
        let detector = try self.makeDetector(memoryContent: memoryContent)
        _ = detector.detect(userText: "Warm the cache for Atlas migration")

        let iterations = 200
        let clock = ContinuousClock()

        // When
        let start = clock.now
        for _ in 0..<iterations {
            _ = detector.detect(userText: "Did we decide Atlas rollout next steps?")
        }
        let elapsed = start.duration(to: clock.now)
        let elapsedMilliseconds = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let averageMilliseconds = Double(elapsedMilliseconds) / Double(iterations)

        // Then
        XCTAssertLessThan(averageMilliseconds, 5.0)
    }

    func test_detect_entityIndexCacheInvalidatesWhenMemoryFileChanges() throws {
        // Given
        let memoryFileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md", isDirectory: false)
        let initialMemoryContent = """
# Ora Memory

## Projects
- [fact] Atlas rollout is blocked on staging.
"""
        try initialMemoryContent.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        let detector = MemoryTriggerDetector(memoryFileURL: memoryFileURL)

        // Warm cache with initial file content.
        let initialResult = detector.detect(userText: "Any update on Atlas rollout?")
        XCTAssertTrue(initialResult.shouldTrigger)
        XCTAssertTrue(initialResult.matchedSignals.contains("atlas"))

        // When
        let updatedMemoryContent = """
# Ora Memory

## Projects
- [fact] Helios launch depends on release coordination details and checklist.
"""
        try updatedMemoryContent.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        let result = detector.detect(userText: "Any update on Helios launch?")

        // Then
        XCTAssertTrue(result.shouldTrigger)
        XCTAssertEqual(result.triggerType, .entityOverlap)
        XCTAssertTrue(result.matchedSignals.contains("helios"))
    }

    func test_detect_entityIndexLoadFailureDoesNotCacheEmptyResult() throws {
        // Given
        let memoryFileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md", isDirectory: false)
        let detector = MemoryTriggerDetector(memoryFileURL: memoryFileURL)

        // Initial detect occurs before MEMORY.md exists.
        let firstResult = detector.detect(userText: "Any update on Atlas rollout?")
        XCTAssertFalse(firstResult.shouldTrigger)

        // When
        let memoryContent = """
# Ora Memory

## Projects
- [fact] Atlas rollout has release blockers.
"""
        try memoryContent.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        let secondResult = detector.detect(userText: "Any update on Atlas rollout?")

        // Then
        XCTAssertTrue(secondResult.shouldTrigger)
        XCTAssertEqual(secondResult.triggerType, .entityOverlap)
        XCTAssertTrue(secondResult.matchedSignals.contains("atlas"))
    }

    // MARK: - Helpers

    private func makeDetector(memoryContent: String) throws -> MemoryTriggerDetector {
        let memoryFileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md", isDirectory: false)
        try memoryContent.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        return MemoryTriggerDetector(memoryFileURL: memoryFileURL)
    }
}
