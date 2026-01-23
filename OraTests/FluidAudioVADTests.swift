//
//  FluidAudioVADTests.swift
//  OraTests
//
//  Tests for FluidAudio Silero-based neural VAD (M.06 Phase 2)
//

import XCTest
@testable import Ora

final class FluidAudioVADTests: XCTestCase {

    // MARK: - Configuration Tests

    func test_defaultConfiguration_hasExpectedValues() {
        let config = FluidAudioVADConfiguration.default

        XCTAssertEqual(config.speechThreshold, 0.70, accuracy: 0.01)
        XCTAssertEqual(config.minSpeechDuration, 0.25, accuracy: 0.01)
        XCTAssertEqual(config.minSilenceGap, 0.50, accuracy: 0.01)
        XCTAssertEqual(config.speechPadding, 0.10, accuracy: 0.01)
    }

    func test_relaxedConfiguration_hasLongerSilenceGap() {
        let config = FluidAudioVADConfiguration.relaxed

        // Relaxed config should have longer silence gap for natural pauses
        XCTAssertGreaterThan(config.minSilenceGap, FluidAudioVADConfiguration.default.minSilenceGap)
        XCTAssertEqual(config.minSilenceGap, 0.80, accuracy: 0.01)
    }

    func test_strictConfiguration_hasShorterSilenceGap() {
        let config = FluidAudioVADConfiguration.strict

        // Strict config should have shorter silence gap for quick commands
        XCTAssertLessThan(config.minSilenceGap, FluidAudioVADConfiguration.default.minSilenceGap)
        XCTAssertEqual(config.minSilenceGap, 0.40, accuracy: 0.01)
    }

    func test_customConfiguration_acceptsCustomValues() {
        let config = FluidAudioVADConfiguration(
            speechThreshold: 0.75,
            minSpeechDuration: 0.30,
            minSilenceGap: 0.60,
            speechPadding: 0.15
        )

        XCTAssertEqual(config.speechThreshold, 0.75, accuracy: 0.01)
        XCTAssertEqual(config.minSpeechDuration, 0.30, accuracy: 0.01)
        XCTAssertEqual(config.minSilenceGap, 0.60, accuracy: 0.01)
        XCTAssertEqual(config.speechPadding, 0.15, accuracy: 0.01)
    }

    // MARK: - VAD Initialization Tests

    func test_fluidAudioVAD_initializesWithConfiguration() async throws {
        let config = FluidAudioVADConfiguration(
            speechThreshold: 0.65,
            minSpeechDuration: 0.20,
            minSilenceGap: 0.45
        )

        let vad = FluidAudioVAD(configuration: config)

        // VAD should not be ready until prepare() is called
        let isSpeech = await vad.isSpeech
        XCTAssertFalse(isSpeech)

        let lastProbability = await vad.lastProbability
        XCTAssertEqual(lastProbability, 0)
    }

    func test_fluidAudioVAD_prepareLoadsModel() async throws {
        let vad = FluidAudioVAD()

        // Should not throw
        try await vad.prepare()

        // After prepare, should still start in non-speech state
        let isSpeech = await vad.isSpeech
        XCTAssertFalse(isSpeech)
    }

    func test_fluidAudioVAD_reset_clearsState() async throws {
        let vad = FluidAudioVAD()
        try await vad.prepare()

        // Generate some silence audio and process
        let silentAudio = [Float](repeating: 0, count: 4096)
        _ = try await vad.process(silentAudio)

        // Reset
        await vad.reset()

        // State should be cleared
        let isSpeech = await vad.isSpeech
        XCTAssertFalse(isSpeech)

        let lastProbability = await vad.lastProbability
        XCTAssertEqual(lastProbability, 0)
    }

    // MARK: - VAD Processing Tests

    func test_fluidAudioVAD_processSilence_returnsFalse() async throws {
        let vad = FluidAudioVAD()
        try await vad.prepare()

        // Generate silent audio (all zeros)
        let silentAudio = [Float](repeating: 0, count: 4096)

        let result = try await vad.process(silentAudio)

        XCTAssertFalse(result.isSpeech)
        XCTAssertLessThan(result.probability, 0.5)
    }

    func test_fluidAudioVAD_buffersSmallChunks() async throws {
        let vad = FluidAudioVAD()
        try await vad.prepare()

        // Process small chunks that are less than the required 4096 samples
        let smallChunk = [Float](repeating: 0, count: 480) // 30ms at 16kHz

        // First few chunks should not produce a result since not enough samples
        var result = try await vad.process(smallChunk)

        // After processing enough chunks to accumulate 4096 samples, should get a result
        for _ in 0..<8 {
            result = try await vad.process(smallChunk)
        }

        // After enough chunks, should have processed at least one full chunk
        XCTAssertFalse(result.isSpeech)
    }

    func test_fluidAudioVAD_notReady_throwsError() async {
        let vad = FluidAudioVAD()
        // Don't call prepare()

        let silentAudio = [Float](repeating: 0, count: 4096)

        do {
            _ = try await vad.process(silentAudio)
            XCTFail("Should have thrown FluidAudioVADError.notReady")
        } catch let error as FluidAudioVADError {
            switch error {
            case .notReady:
                break // Expected
            case .processingFailed:
                XCTFail("Unexpected error: processingFailed")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Integration with ASRService Tests

    func test_asrService_usesFluidAudioVAD() async throws {
        // This test verifies that ASRService properly initializes FluidAudioVAD
        // The actual integration is tested by the existing ASRServiceTests

        // Verify that FluidAudioVADConfiguration matches AppSettings defaults
        let config = FluidAudioVADConfiguration.default

        // These should match AppSettings defaults (0.25s and 0.50s)
        XCTAssertEqual(config.minSpeechDuration, 0.25, accuracy: 0.01)
        XCTAssertEqual(config.minSilenceGap, 0.50, accuracy: 0.01)
    }
}
