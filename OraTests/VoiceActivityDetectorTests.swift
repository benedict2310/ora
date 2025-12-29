//
//  VoiceActivityDetectorTests.swift
//  OraTests
//
//  Tests for EnergyVAD voice activity detection.
//

import XCTest
@testable import Ora

final class VoiceActivityDetectorTests: XCTestCase {

    // MARK: - Speech Detection

    /// TC-3.1: Speech detected at threshold
    func test_speechDetectedAtThreshold() {
        var vad = EnergyVAD(speechThreshold: 0.01, silenceThreshold: 0.005)

        // Generate samples above threshold
        let loudSamples = [Float](repeating: 0.1, count: 480)
        let result = vad.process(loudSamples)

        XCTAssertTrue(result.isSpeech, "Should detect speech above threshold")
        XCTAssertEqual(result.transitionType, .speechStart, "Should emit speechStart transition")
    }

    /// TC-3.2: Silence detected below threshold
    func test_silenceDetectedBelowThreshold() {
        var vad = EnergyVAD(
            speechThreshold: 0.01,
            silenceThreshold: 0.005,
            hangoverFrames: 0  // Disable for test
        )

        // First detect speech
        let loudSamples = [Float](repeating: 0.1, count: 480)
        _ = vad.process(loudSamples)

        // Then silence
        let quietSamples = [Float](repeating: 0.001, count: 480)
        let result = vad.process(quietSamples)

        XCTAssertFalse(result.isSpeech, "Should detect silence below threshold")
        XCTAssertEqual(result.transitionType, .speechEnd, "Should emit speechEnd transition")
    }

    /// TC-3.3: Hangover prevents premature cutoff
    func test_hangoverPreventsPrematureCutoff() {
        var vad = EnergyVAD(
            speechThreshold: 0.01,
            silenceThreshold: 0.005,
            hangoverFrames: 3
        )

        // Establish speech
        let loudSamples = [Float](repeating: 0.1, count: 480)
        _ = vad.process(loudSamples)

        // Brief silence (within hangover)
        let quietSamples = [Float](repeating: 0.001, count: 480)
        let result1 = vad.process(quietSamples)
        let result2 = vad.process(quietSamples)

        XCTAssertTrue(result1.isSpeech, "Still speech during hangover frame 1")
        XCTAssertTrue(result2.isSpeech, "Still speech during hangover frame 2")
        XCTAssertNil(result1.transitionType, "No transition during hangover")
    }

    /// TC-3.4: Hangover expires and speech ends
    func test_hangoverExpiresCorrectly() {
        var vad = EnergyVAD(
            speechThreshold: 0.01,
            silenceThreshold: 0.005,
            hangoverFrames: 2
        )

        // Establish speech
        let loudSamples = [Float](repeating: 0.1, count: 480)
        _ = vad.process(loudSamples)

        // Wait through hangover
        let quietSamples = [Float](repeating: 0.001, count: 480)
        _ = vad.process(quietSamples)  // hangover = 1
        _ = vad.process(quietSamples)  // hangover = 0
        let result = vad.process(quietSamples)  // transition!

        XCTAssertFalse(result.isSpeech, "Speech should end after hangover")
        XCTAssertEqual(result.transitionType, .speechEnd, "Should emit speechEnd")
    }

    /// TC-3.5: Reset clears state
    func test_resetClearsState() {
        var vad = EnergyVAD()

        let loudSamples = [Float](repeating: 0.1, count: 480)
        _ = vad.process(loudSamples)

        XCTAssertTrue(vad.isSpeech, "Should be in speech state")

        vad.reset()

        XCTAssertFalse(vad.isSpeech, "Should be reset to silence")
    }

    /// TC-3.6: Hysteresis prevents oscillation
    func test_hysteresisPreventsOscillation() {
        var vad = EnergyVAD(
            speechThreshold: 0.02,
            silenceThreshold: 0.01,
            hangoverFrames: 0
        )

        // Energy between thresholds - start in silence
        let ambiguousSamples = [Float](repeating: 0.015, count: 480)

        // Process multiple times from silence state
        let result1 = vad.process(ambiguousSamples)
        let result2 = vad.process(ambiguousSamples)
        let result3 = vad.process(ambiguousSamples)

        // All should maintain same state (silence, since energy < speechThreshold)
        XCTAssertEqual(result1.isSpeech, result2.isSpeech, "State should be consistent")
        XCTAssertEqual(result2.isSpeech, result3.isSpeech, "State should be consistent")
    }

    // MARK: - Empty Input

    func test_emptyInputHandled() {
        var vad = EnergyVAD()

        let result = vad.process([])

        XCTAssertFalse(result.isSpeech, "Empty input should not trigger speech")
        XCTAssertEqual(result.energy, 0, "Energy should be 0 for empty input")
    }

    // MARK: - Frame Counts

    func test_frameCountsIncrement() {
        var vad = EnergyVAD(speechThreshold: 0.01, silenceThreshold: 0.005, hangoverFrames: 0)

        // Speech frames
        let loudSamples = [Float](repeating: 0.1, count: 480)
        _ = vad.process(loudSamples)
        let result1 = vad.process(loudSamples)
        XCTAssertEqual(result1.speechFrameCount, 2, "Speech frame count should increment")

        // Reset to silence
        vad.reset()

        // Silence frames
        let quietSamples = [Float](repeating: 0.001, count: 480)
        _ = vad.process(quietSamples)
        let result2 = vad.process(quietSamples)
        XCTAssertEqual(result2.silenceFrameCount, 2, "Silence frame count should increment")
    }

    // MARK: - Configuration Presets

    func test_quietPreset() {
        let config = VADConfiguration.quiet
        XCTAssertEqual(config.speechThreshold, 0.008)
        XCTAssertEqual(config.silenceThreshold, 0.003)
        XCTAssertEqual(config.hangoverFrames, 10)
    }

    func test_noisyPreset() {
        let config = VADConfiguration.noisy
        XCTAssertEqual(config.speechThreshold, 0.02)
        XCTAssertEqual(config.silenceThreshold, 0.01)
        XCTAssertEqual(config.hangoverFrames, 6)
    }

    // MARK: - Barge-in

    /// TC-7.1: Barge-in detection (user interrupts during hangover)
    func test_bargeInDetection() {
        var vad = EnergyVAD(hangoverFrames: 5)

        // Establish speech
        let loudSamples = [Float](repeating: 0.1, count: 480)
        _ = vad.process(loudSamples)

        // Brief silence (within hangover)
        let quietSamples = [Float](repeating: 0.001, count: 480)
        _ = vad.process(quietSamples)
        _ = vad.process(quietSamples)

        // Barge-in with new speech (before hangover expires)
        let result = vad.process(loudSamples)

        XCTAssertTrue(result.isSpeech, "Should still be in speech state")
        XCTAssertNil(result.transitionType, "No transition for barge-in continuation")
    }
}
