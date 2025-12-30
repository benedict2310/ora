//
//  PartialDifferTests.swift
//  OraTests
//
//  Tests for PartialDiffer text diffing.
//

import XCTest
@testable import Ora

final class PartialDifferTests: XCTestCase {

    // MARK: - Basic Diffing

    /// TC-2.1: New text detected correctly
    func test_newTextDetected() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        let result1 = differ.process("Hello")
        XCTAssertEqual(result1.newText, "Hello", "First text should be new")
        XCTAssertEqual(result1.fullText, "Hello")
        XCTAssertFalse(result1.isStable, "Should not be stable yet")

        let result2 = differ.process("Hello world")
        XCTAssertEqual(result2.newText, "world", "Only new portion should be returned")
        XCTAssertEqual(result2.fullText, "Hello world")
    }

    /// TC-2.2: Stability detected after threshold
    func test_stabilityDetected() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        _ = differ.process("Hello world")
        _ = differ.process("Hello world")
        let result = differ.process("Hello world")

        XCTAssertTrue(result.isStable, "Should be stable after threshold")
        XCTAssertEqual(result.confirmedText, "Hello world")
    }

    /// TC-2.3: Corrections handled gracefully
    func test_correctionsHandled() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        _ = differ.process("Hello word")  // Typo
        let result = differ.process("Hello world")  // Correction

        XCTAssertEqual(result.fullText, "Hello world", "Should handle correction")
    }

    /// TC-2.4: Reset clears all state
    func test_resetClearsState() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        _ = differ.process("Hello world")
        _ = differ.process("Hello world")

        differ.reset()

        let result = differ.process("New text")
        XCTAssertEqual(result.fullText, "New text")
        XCTAssertEqual(result.confirmedText, "", "Confirmed should be empty after reset")
    }

    /// TC-2.5: Confirmed text preserved across updates
    func test_confirmedTextPreserved() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        // Confirm first phrase
        _ = differ.process("Hello")
        _ = differ.process("Hello")
        _ = differ.process("Hello")

        // Add new text
        let result = differ.process("Hello world")

        XCTAssertEqual(result.confirmedText, "Hello")
        XCTAssertEqual(result.pendingText, "world")
    }

    /// TC-2.6: Empty input handled
    func test_emptyInputHandled() {
        var differ = PartialDiffer()

        let result = differ.process("")
        XCTAssertEqual(result.fullText, "")
        XCTAssertFalse(result.isStable)
    }

    // MARK: - Whitespace Handling

    func test_whitespaceTrimmingWorks() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        let result = differ.process("  Hello world  ")
        XCTAssertEqual(result.fullText, "Hello world")
    }

    // MARK: - Stability Threshold Variations

    func test_stabilityThresholdOne() {
        var differ = PartialDiffer(stabilityThreshold: 1)

        _ = differ.process("Hello")
        let result = differ.process("Hello")

        XCTAssertTrue(result.isStable, "Should be stable with threshold 1")
    }

    func test_stabilityThresholdThree() {
        var differ = PartialDiffer(stabilityThreshold: 3)

        _ = differ.process("Hello")
        _ = differ.process("Hello")
        let result2 = differ.process("Hello")
        XCTAssertFalse(result2.isStable, "Should not be stable yet")

        let result3 = differ.process("Hello")
        XCTAssertTrue(result3.isStable, "Should be stable after 3 identical")
    }

    // MARK: - Edge Cases

    /// TC-7.7: Differ handles ASR corrections mid-word
    func test_differHandlesMidWordCorrections() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        _ = differ.process("I'm going to the sto")  // Partial word
        _ = differ.process("I'm going to the store")  // Completed (count=0)
        _ = differ.process("I'm going to the store")  // count=1
        let result = differ.process("I'm going to the store")  // count=2, stable!

        XCTAssertTrue(result.isStable)
        XCTAssertEqual(result.confirmedText, "I'm going to the store")
    }

    /// TC-7.5: Unicode text handled correctly
    func test_unicodeTextHandled() {
        var differ = PartialDiffer()

        _ = differ.process("Hello")
        let result = differ.process("Hello world café")

        XCTAssertTrue(result.fullText.contains("café"))
    }

    func test_multibyteCharacters() {
        var differ = PartialDiffer()

        let result1 = differ.process("こんにちは")
        XCTAssertEqual(result1.fullText, "こんにちは")

        let result2 = differ.process("こんにちは世界")
        XCTAssertEqual(result2.fullText, "こんにちは世界")
    }

    // MARK: - Multi-Segment Flow

    func test_multiSegmentFlow() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        // First segment
        _ = differ.process("Hello")
        _ = differ.process("Hello")
        _ = differ.process("Hello")
        XCTAssertEqual(differ.confirmedText, "Hello")

        // Continue with more text
        _ = differ.process("Hello world")
        _ = differ.process("Hello world")
        _ = differ.process("Hello world")

        // Confirmed should now include both
        XCTAssertEqual(differ.confirmedText, "Hello world")
    }

    // MARK: - Case Sensitivity

    func test_caseInsensitiveMatching() {
        var differ = PartialDiffer(stabilityThreshold: 2)

        // Confirm text
        _ = differ.process("Hello")
        _ = differ.process("Hello")
        _ = differ.process("Hello")

        // Add with different case (engine might change casing)
        let result = differ.process("HELLO world")

        // Should still extract "world" as new
        XCTAssertEqual(result.pendingText, "world")
    }
}
