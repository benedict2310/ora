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

    func test_minimumTimeout_is0Point5Seconds() {
        XCTAssertEqual(SilenceDetector.minimumTimeout, 0.5)
    }

    func test_maximumTimeout_is3Seconds() {
        XCTAssertEqual(SilenceDetector.maximumTimeout, 3.0)
    }

    func test_vadConfirmationDelay_is800ms() {
        XCTAssertEqual(SilenceDetector.vadConfirmationDelay, 0.8)
    }

    func test_init_usesDefaultTimeout() {
        let detector = SilenceDetector()
        XCTAssertEqual(detector.timeout, 1.5)
    }

    func test_init_withCustomTimeout() {
        let detector = SilenceDetector(timeout: 1.5)
        XCTAssertEqual(detector.timeout, 1.5)
    }

    func test_init_clampsTimeoutToMinimum() {
        let detector = SilenceDetector(timeout: 0.1)
        XCTAssertEqual(detector.timeout, SilenceDetector.minimumTimeout)
    }

    func test_init_clampsTimeoutToMaximum() {
        let detector = SilenceDetector(timeout: 5.0)
        XCTAssertEqual(detector.timeout, SilenceDetector.maximumTimeout)
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

    // MARK: - isVADAssistedModeActive Tests

    func test_isVADAssistedModeActive_initiallyFalse() {
        let detector = SilenceDetector()
        XCTAssertFalse(detector.isVADAssistedModeActive)
    }

    func test_isVADAssistedModeActive_trueAfterVADEvent() {
        let detector = SilenceDetector()
        detector.onVADStateChanged(isSpeech: true)
        XCTAssertTrue(detector.isVADAssistedModeActive)
    }

    func test_isVADAssistedModeActive_falseAfterReset() {
        let detector = SilenceDetector()
        detector.onVADStateChanged(isSpeech: true)
        detector.reset()
        XCTAssertFalse(detector.isVADAssistedModeActive)
    }

    // MARK: - ASR-based Silence Detection Tests

    func test_silenceDetected_afterTimeout() async {
        let detector = SilenceDetector(timeout: 0.5)  // Use minimum timeout for testing
        let expectation = XCTestExpectation(description: "Silence detected")

        detector.onSilenceDetected = {
            expectation.fulfill()
        }

        // Receive a partial to start the timer
        detector.onPartialReceived()

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_silenceNotDetected_whenCancelled() async {
        let detector = SilenceDetector(timeout: 0.5)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.cancel()

        // Wait longer than the timeout
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertFalse(silenceDetected)
    }

    func test_silenceTimerResets_onNewPartial() async {
        let detector = SilenceDetector(timeout: 0.5)
        var silenceCount = 0

        detector.onSilenceDetected = {
            silenceCount += 1
        }

        // First partial
        detector.onPartialReceived()

        // Wait less than timeout
        try? await Task.sleep(for: .milliseconds(300))

        // Second partial resets timer
        detector.onPartialReceived()

        // Wait less than timeout again
        try? await Task.sleep(for: .milliseconds(300))

        // Third partial resets timer again
        detector.onPartialReceived()

        // Wait for timeout
        try? await Task.sleep(for: .milliseconds(700))

        // Should only fire once (from the last partial)
        XCTAssertEqual(silenceCount, 1)
    }

    func test_noSilenceDetection_beforeFirstPartial() async {
        let detector = SilenceDetector(timeout: 0.5)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        // Don't call onPartialReceived - timer shouldn't start

        // Wait longer than timeout
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertFalse(silenceDetected)
    }

    // MARK: - VAD-assisted Detection Tests

    func test_vadAssistedDetection_triggersOnSpeechEnd() async {
        // AC-4: VAD speechEnd triggers confirmation timer
        let detector = SilenceDetector(timeout: 2.0)  // Long ASR timeout
        let expectation = XCTestExpectation(description: "VAD silence detected")

        detector.onSilenceDetected = {
            expectation.fulfill()
        }

        // Receive a partial to enable silence detection
        detector.onPartialReceived()

        // Simulate speech end
        detector.onVADStateChanged(isSpeech: false)

        // Should fire within confirmation delay + buffer
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_vadConfirmation_cancelledOnSpeechResume() async {
        // AC-5: VAD speechStart cancels pending confirmation
        let detector = SilenceDetector(timeout: 2.0)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        // Receive a partial to enable silence detection
        detector.onPartialReceived()

        // Start confirmation (speech end)
        detector.onVADStateChanged(isSpeech: false)

        // Wait a bit but less than confirmation delay
        try? await Task.sleep(for: .milliseconds(100))

        // Resume speech - should cancel confirmation
        detector.onVADStateChanged(isSpeech: true)

        // Wait longer than confirmation delay
        try? await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay + 0.2))

        XCTAssertFalse(silenceDetected)
    }

    func test_vadConfirmation_triggersAfterDelay() async {
        // AC-4: Confirmation timer fires correctly after delay
        let detector = SilenceDetector(timeout: 2.0)  // Long ASR timeout
        var detectionTime: Date?
        let startTime = Date()

        let expectation = XCTestExpectation(description: "Silence detected")

        detector.onSilenceDetected = {
            detectionTime = Date()
            expectation.fulfill()
        }

        // Receive a partial to enable silence detection
        detector.onPartialReceived()

        // Trigger VAD speech end
        detector.onVADStateChanged(isSpeech: false)

        await fulfillment(of: [expectation], timeout: 2.0)

        // Check that detection happened around the VAD delay after event
        guard let detection = detectionTime else {
            XCTFail("Detection time not recorded")
            return
        }
        let elapsed = detection.timeIntervalSince(startTime)
        let expected = SilenceDetector.vadConfirmationDelay
        XCTAssertGreaterThan(elapsed, max(0.0, expected - 0.2))
        XCTAssertLessThan(elapsed, expected + 0.4)
    }

    func test_partialDuringVADConfirmation_doesNotResetTimer() async {
        // M.06: ASR partial during VAD confirmation does NOT reset the timer
        // This prevents jitter where partials keep cancelling the confirmation
        let detector = SilenceDetector(timeout: 2.0)  // Long ASR timeout so it doesn't interfere
        var silenceCount = 0

        detector.onSilenceDetected = {
            silenceCount += 1
        }

        // Receive a partial to enable silence detection
        detector.onPartialReceived(text: "Hello")

        // Start VAD confirmation
        detector.onVADStateChanged(isSpeech: false)

        // Verify confirmation is in progress
        XCTAssertTrue(detector.isVADConfirmationInProgress)

        // Wait a bit (less than confirmation delay)
        try? await Task.sleep(for: .milliseconds(100))

        // New partial should NOT cancel VAD confirmation (M.06 change)
        detector.onPartialReceived(text: "Hello world")

        // Confirmation should still be in progress
        XCTAssertTrue(detector.isVADConfirmationInProgress)

        // Wait for VAD confirmation to complete
        try? await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay + 0.2))

        // Silence should have been detected via VAD confirmation
        // (partial did not cancel it)
        XCTAssertEqual(silenceCount, 1)
    }

    func test_speechStartCancelsVADConfirmation() async {
        // Speech resuming (not just a partial) should cancel VAD confirmation
        let detector = SilenceDetector(timeout: 2.0)
        var silenceCount = 0

        detector.onSilenceDetected = {
            silenceCount += 1
        }

        // Receive a partial to enable silence detection
        detector.onPartialReceived(text: "Hello")

        // Start VAD confirmation (speech ended)
        detector.onVADStateChanged(isSpeech: false)
        XCTAssertTrue(detector.isVADConfirmationInProgress)

        // Wait a bit
        try? await Task.sleep(for: .milliseconds(100))

        // Speech resumes - this SHOULD cancel confirmation
        detector.onVADStateChanged(isSpeech: true)
        XCTAssertFalse(detector.isVADConfirmationInProgress)

        // Wait longer than confirmation delay
        try? await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay + 0.2))

        // Silence should NOT have been detected (speech resumed)
        XCTAssertEqual(silenceCount, 0)
    }

    func test_vadSpeechEndWithoutPartial_doesNotTrigger() async {
        // AC-6: Confirmation timer respects minimum transcript length
        let detector = SilenceDetector(timeout: 2.0)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        // No partial received - no content to submit

        // VAD speech end
        detector.onVADStateChanged(isSpeech: false)

        // Wait longer than confirmation delay
        try? await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay + 0.2))

        // Should not trigger because no partial was received
        XCTAssertFalse(silenceDetected)
    }

    // MARK: - Fallback Tests

    func test_fallbackToASROnly_whenNoVADEvents() async {
        // AC-8: System falls back to ASR-only if VAD events unavailable
        let detector = SilenceDetector(timeout: 0.5)
        let expectation = XCTestExpectation(description: "ASR fallback triggered")

        detector.onSilenceDetected = {
            expectation.fulfill()
        }

        // Only use partial - no VAD events
        detector.onPartialReceived()

        // Should fire after ASR timeout
        await fulfillment(of: [expectation], timeout: 2.0)

        // VAD mode should still be inactive since no VAD events received
        XCTAssertFalse(detector.isVADAssistedModeActive)
    }

    // MARK: - Reset Tests

    func test_reset_cancelsTimer() async {
        let detector = SilenceDetector(timeout: 0.5)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.reset()

        // Wait longer than timeout
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertFalse(silenceDetected)
    }

    func test_reset_cancelsVADConfirmation() async {
        let detector = SilenceDetector(timeout: 2.0)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.onVADStateChanged(isSpeech: false)

        // Reset before confirmation fires
        detector.reset()

        // Wait longer than confirmation delay
        try? await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay + 0.2))

        XCTAssertFalse(silenceDetected)
    }

    func test_reset_allowsNewSession() async {
        let detector = SilenceDetector(timeout: 0.5)
        let expectation = XCTestExpectation(description: "Silence detected")

        detector.onSilenceDetected = {
            expectation.fulfill()
        }

        // First session
        detector.onPartialReceived()
        detector.reset()

        // New session
        detector.onPartialReceived()

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Cancel Tests

    func test_cancel_stopsTimer() async {
        let detector = SilenceDetector(timeout: 0.5)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.cancel()

        // Wait longer than timeout
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertFalse(silenceDetected)
    }

    func test_cancel_stopsVADConfirmation() async {
        let detector = SilenceDetector(timeout: 2.0)
        var silenceDetected = false

        detector.onSilenceDetected = {
            silenceDetected = true
        }

        detector.onPartialReceived()
        detector.onVADStateChanged(isSpeech: false)
        detector.cancel()

        // Wait longer than confirmation delay
        try? await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay + 0.2))

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
        let detector = SilenceDetector(timeout: 0.5)
        let expectation = XCTestExpectation(description: "Callback called")

        detector.onSilenceDetected = {
            // This should compile without isolation errors since detector is @MainActor
            MainActor.assertIsolated()
            expectation.fulfill()
        }

        detector.onPartialReceived()

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - M.06 New Features Tests

    func test_noChangeTimeout_constant() {
        XCTAssertEqual(SilenceDetector.noChangeTimeout, 1.5)
    }

    func test_hardMaxDuration_constant() {
        XCTAssertEqual(SilenceDetector.hardMaxDuration, 60.0)
    }

    func test_noChangeTimeout_triggersAfterStableText() async {
        // M.06: Finalize after text unchanged for noChangeTimeout
        let detector = SilenceDetector(timeout: 5.0)  // Long ASR timeout
        let expectation = XCTestExpectation(description: "No-change timeout triggered")

        detector.onSilenceDetected = {
            expectation.fulfill()
        }

        // Receive initial partial
        detector.onPartialReceived(text: "Hello world")

        // Should fire after noChangeTimeout + buffer
        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func test_noChangeTimeout_resetsOnTextChange() async {
        // M.06: Text change resets no-change timer
        let detector = SilenceDetector(timeout: 5.0)  // Long ASR timeout
        var silenceCount = 0

        detector.onSilenceDetected = {
            silenceCount += 1
        }

        // Receive initial partial
        detector.onPartialReceived(text: "Hello")

        // Wait less than no-change timeout
        try? await Task.sleep(for: .milliseconds(300))

        // New text resets the timer
        detector.onPartialReceived(text: "Hello world")

        // Wait less than no-change timeout again
        try? await Task.sleep(for: .milliseconds(300))

        // Should not have triggered yet (timer was reset)
        XCTAssertEqual(silenceCount, 0)

        // Wait for timeout after last change
        try? await Task.sleep(for: .seconds(SilenceDetector.noChangeTimeout + 0.2))

        // Now should have triggered
        XCTAssertEqual(silenceCount, 1)
    }

    func test_isVADConfirmationInProgress_property() {
        let detector = SilenceDetector(timeout: 2.0)

        // Initially false
        XCTAssertFalse(detector.isVADConfirmationInProgress)

        // Receive partial first
        detector.onPartialReceived(text: "Hello")

        // Trigger VAD speech end
        detector.onVADStateChanged(isSpeech: false)

        // Should now be true
        XCTAssertTrue(detector.isVADConfirmationInProgress)

        // Cancel should clear it
        detector.cancel()
        XCTAssertFalse(detector.isVADConfirmationInProgress)
    }
}
