//
//  TranscriptStabilizerTests.swift
//  OraTests
//
//  Tests for TranscriptStabilizer text stability detection.
//

import XCTest
@testable import Ora

final class TranscriptStabilizerTests: XCTestCase {

    // MARK: - Basic Emission Tests

    func test_shouldEmit_trueForFirstText() {
        var stabilizer = TranscriptStabilizer()

        XCTAssertTrue(stabilizer.shouldEmit("Hello"))
        XCTAssertEqual(stabilizer.lastEmitted, "Hello")
    }

    func test_shouldEmit_trueForMeaningfulChange() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello")
        XCTAssertTrue(stabilizer.shouldEmit("Hello world"))
        XCTAssertEqual(stabilizer.lastEmitted, "Hello world")
    }

    func test_shouldEmit_falseForIdenticalText() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello world")
        XCTAssertFalse(stabilizer.shouldEmit("Hello world"))
        // lastEmitted should not change
        XCTAssertEqual(stabilizer.lastEmitted, "Hello world")
    }

    // MARK: - Punctuation Tests

    func test_shouldEmit_falseForPunctuationOnlyChange() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello world")
        // Adding period should not trigger emission
        XCTAssertFalse(stabilizer.shouldEmit("Hello world."))
    }

    func test_shouldEmit_falseForPunctuationVariation() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello world!")
        // Changing punctuation should not trigger emission
        XCTAssertFalse(stabilizer.shouldEmit("Hello world?"))
    }

    func test_shouldEmit_falseForRemovingPunctuation() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello world.")
        // Removing punctuation should not trigger emission
        XCTAssertFalse(stabilizer.shouldEmit("Hello world"))
    }

    // MARK: - Capitalization Tests

    func test_shouldEmit_falseForCapitalizationChange() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("hello world")
        // Changing capitalization should not trigger emission
        XCTAssertFalse(stabilizer.shouldEmit("Hello world"))
    }

    func test_shouldEmit_falseForAllCapsChange() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello World")
        XCTAssertFalse(stabilizer.shouldEmit("HELLO WORLD"))
    }

    // MARK: - Word Addition/Removal Tests

    func test_shouldEmit_trueForAddedWord() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello")
        XCTAssertTrue(stabilizer.shouldEmit("Hello there"))
    }

    func test_shouldEmit_trueForRemovedWord() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello there friend")
        XCTAssertTrue(stabilizer.shouldEmit("Hello friend"))
    }

    func test_shouldEmit_trueForReplacedWord() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello world")
        XCTAssertTrue(stabilizer.shouldEmit("Hello there"))
    }

    // MARK: - Stability Tracking Tests

    func test_isStable_falseInitially() {
        let stabilizer = TranscriptStabilizer(stabilityThreshold: 2)
        XCTAssertFalse(stabilizer.isStable)
    }

    func test_isStable_trueAfterRepeatedText() {
        var stabilizer = TranscriptStabilizer(stabilityThreshold: 2)

        _ = stabilizer.shouldEmit("Hello world")
        XCTAssertFalse(stabilizer.isStable)

        _ = stabilizer.shouldEmit("Hello world")
        XCTAssertFalse(stabilizer.isStable)

        _ = stabilizer.shouldEmit("Hello world")
        XCTAssertTrue(stabilizer.isStable)
    }

    func test_isStable_resetOnTextChange() {
        var stabilizer = TranscriptStabilizer(stabilityThreshold: 2)

        // Get stable
        _ = stabilizer.shouldEmit("Hello")
        _ = stabilizer.shouldEmit("Hello")
        _ = stabilizer.shouldEmit("Hello")
        XCTAssertTrue(stabilizer.isStable)

        // Text changes - stability resets
        _ = stabilizer.shouldEmit("Hello world")
        XCTAssertFalse(stabilizer.isStable)
    }

    // MARK: - Time Tracking Tests

    func test_timeSinceLastChange_nilInitially() {
        let stabilizer = TranscriptStabilizer()
        XCTAssertNil(stabilizer.timeSinceLastChange)
    }

    func test_timeSinceLastChange_updatedOnChange() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello")

        // Should have a value now
        XCTAssertNotNil(stabilizer.timeSinceLastChange)

        // Should be very small (just happened)
        XCTAssertLessThan(stabilizer.timeSinceLastChange!, 0.1)
    }

    func test_hasBeenStableFor_falseWhenNeverChecked() {
        let stabilizer = TranscriptStabilizer()
        XCTAssertFalse(stabilizer.hasBeenStableFor(0.1))
    }

    // MARK: - Reset Tests

    func test_reset_clearsAllState() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello world")
        _ = stabilizer.shouldEmit("Hello world")

        stabilizer.reset()

        XCTAssertEqual(stabilizer.lastEmitted, "")
        XCTAssertFalse(stabilizer.isStable)
        XCTAssertNil(stabilizer.timeSinceLastChange)
    }

    func test_reset_allowsNewSession() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello")
        stabilizer.reset()

        // Should emit same text again after reset
        XCTAssertTrue(stabilizer.shouldEmit("Hello"))
    }

    // MARK: - Edge Cases

    func test_shouldEmit_handlesEmptyString() {
        var stabilizer = TranscriptStabilizer()

        XCTAssertFalse(stabilizer.shouldEmit(""))
        XCTAssertEqual(stabilizer.lastEmitted, "")
    }

    func test_shouldEmit_trueForEmptyToNonEmpty() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("")
        XCTAssertTrue(stabilizer.shouldEmit("Hello"))
    }

    func test_shouldEmit_trueForNonEmptyToEmpty() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello")
        XCTAssertTrue(stabilizer.shouldEmit(""))
    }

    func test_shouldEmit_handlesWhitespaceVariations() {
        var stabilizer = TranscriptStabilizer()

        _ = stabilizer.shouldEmit("Hello world")
        // Extra whitespace should normalize
        XCTAssertFalse(stabilizer.shouldEmit("Hello world  "))
        XCTAssertFalse(stabilizer.shouldEmit("  Hello world"))
    }

    // MARK: - Configuration Tests

    func test_init_customStabilityThreshold() {
        let stabilizer = TranscriptStabilizer(stabilityThreshold: 5)
        XCTAssertEqual(stabilizer.stabilityThreshold, 5)
    }

    func test_init_customMinCharacterDifference() {
        let stabilizer = TranscriptStabilizer(minCharacterDifference: 3)
        XCTAssertEqual(stabilizer.minCharacterDifference, 3)
    }
}
