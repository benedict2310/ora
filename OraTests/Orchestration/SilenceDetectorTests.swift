//
//  SilenceDetectorTests.swift
//  OraTests
//
//  Tests for SilenceDetector
//

import XCTest
@testable import Ora

@MainActor
final class SilenceDetectorTests: XCTestCase {

    // MARK: - Constants Tests

    func test_defaultTimeout_is1Point5Seconds() {
        XCTAssertEqual(SilenceDetector.defaultTimeout, 1.5)
    }

    func test_init_usesDefaultTimeout() {
        let detector = SilenceDetector()
        XCTAssertEqual(detector.timeout, 1.5)
    }

    func test_init_withCustomTimeout() {
        let detector = SilenceDetector(timeout: 2.0)
        XCTAssertEqual(detector.timeout, 2.0)
    }

    // MARK: - hasStartedListening Tests

    func test_hasStartedListening_initiallyFalse() {
        let detector = SilenceDetector()
        XCTAssertFalse(detector.hasStartedListening)
    }

    func test_hasStartedListening_trueAfterPartial() {
        let detector = SilenceDetector()
        detector.onPartialReceived()
        XCTAssertTrue(detector.hasStartedListening)
    }

    func test_hasStartedListening_falseAfterReset() {
        let detector = SilenceDetector()
        detector.onPartialReceived()
        detector.reset()
        XCTAssertFalse(detector.hasStartedListening)
    }

    // MARK: - Silence Detection Tests (AC-1, AC-2, AC-3)

    func test_silenceDetected_afterTimeout() async {
        let detector = SilenceDetector(timeout: 0.1) // Short timeout for testing
        let expectation = XCTestExpectation(description: "Silence detected")

        detector.onSilenceDetected = {
            expectation.fulfill()
        }

        // Receive a partial to start the timer (AC-2)
        detector.onPartialReceived()

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func test_silenceNotDetected_whenCancelled() async {
        let detector = SilenceDetector(timeout: 0.1)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.cancel()

        // Wait longer than the timeout
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(silenceDetected)
    }

    func test_silenceTimerResets_onNewPartial() async {
        // AC-3: Timer resets on each new partial
        let detector = SilenceDetector(timeout: 0.15)
        var silenceCount = 0

        detector.onSilenceDetected = {
            silenceCount += 1
        }

        // First partial
        detector.onPartialReceived()

        // Wait less than timeout
        try? await Task.sleep(for: .milliseconds(100))

        // Second partial resets timer
        detector.onPartialReceived()

        // Wait less than timeout again
        try? await Task.sleep(for: .milliseconds(100))

        // Third partial resets timer again
        detector.onPartialReceived()

        // Wait for timeout
        try? await Task.sleep(for: .milliseconds(200))

        // Should only fire once (from the last partial)
        XCTAssertEqual(silenceCount, 1)
    }

    func test_noSilenceDetection_beforeFirstPartial() async {
        // AC-2: Timer only starts after receiving at least one partial
        let detector = SilenceDetector(timeout: 0.1)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        // Don't call onPartialReceived - timer shouldn't start

        // Wait longer than timeout
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(silenceDetected)
    }

    // MARK: - Reset Tests

    func test_reset_cancelsTimer() async {
        let detector = SilenceDetector(timeout: 0.1)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.reset()

        // Wait longer than timeout
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(silenceDetected)
    }

    func test_reset_allowsNewSession() async {
        let detector = SilenceDetector(timeout: 0.1)
        let expectation = XCTestExpectation(description: "Silence detected")

        detector.onSilenceDetected = {
            expectation.fulfill()
        }

        // First session
        detector.onPartialReceived()
        detector.reset()

        // New session
        detector.onPartialReceived()

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - Cancel Tests

    func test_cancel_stopsTimer() async {
        let detector = SilenceDetector(timeout: 0.1)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.cancel()

        // Wait longer than timeout
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(silenceDetected)
    }

    func test_cancel_preservesHasStartedListening() {
        let detector = SilenceDetector()

        detector.onPartialReceived()
        XCTAssertTrue(detector.hasStartedListening)

        detector.cancel()
        // Cancel just stops timer, doesn't reset hasStartedListening
        XCTAssertTrue(detector.hasStartedListening)
    }

    // MARK: - Callback Tests

    func test_onSilenceDetected_calledOnMainActor() async {
        let detector = SilenceDetector(timeout: 0.05)
        let expectation = XCTestExpectation(description: "Callback called")

        detector.onSilenceDetected = {
            // This should compile without isolation errors since detector is @MainActor
            MainActor.assertIsolated()
            expectation.fulfill()
        }

        detector.onPartialReceived()

        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
