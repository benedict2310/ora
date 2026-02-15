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

    // MARK: - Helpers

    private func makeDetector(memoryContent: String) throws -> MemoryTriggerDetector {
        let memoryFileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md", isDirectory: false)
        try memoryContent.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        return MemoryTriggerDetector(memoryFileURL: memoryFileURL)
    }
}
