//
//  StreamingManagerTests.swift
//  OraTests
//
//  Tests for StreamingManager orchestration.
//

import XCTest
@preconcurrency import AVFoundation
@testable import Ora

// MARK: - Mock ASR Engine

final class MockASREngine: @unchecked Sendable, ASREngine {
    var isLoaded: Bool = false
    var mockTranscription: String = ""
    var processCallCount: Int = 0
    var finalizeCallCount: Int = 0

    func prepare() async throws {
        isLoaded = true
    }

    func reset() async {
        // No-op for mock
    }

    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {
        // No-op for mock
    }

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        processCallCount += 1
        return ASRPartial(text: mockTranscription, words: [])
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        finalizeCallCount += 1
        return ASRFinalSegment(text: mockTranscription, words: [])
    }
}

// MARK: - StreamingManagerTests

@MainActor
final class StreamingManagerTests: XCTestCase {

    private var manager: StreamingManager!
    private var mockEngine: MockASREngine!
    private var ringBuffer: StreamingRingBuffer!

    override func setUp() async throws {
        try await super.setUp()
        mockEngine = MockASREngine()
        ringBuffer = StreamingRingBuffer(duration: 12.0)

        var config = StreamingConfiguration()
        config.hopInterval = 0.1  // Fast for testing
        config.enableVAD = false   // Disable for deterministic tests
        config.minimumAudioLength = 0.1

        manager = StreamingManager(
            configuration: config,
            engine: mockEngine,
            ringBuffer: ringBuffer
        )
    }

    override func tearDown() async throws {
        await manager?.stop()
        manager = nil
        mockEngine = nil
        ringBuffer = nil
        try await super.tearDown()
    }

    // MARK: - Basic Operation

    /// TC-5.1: Partial callback fired
    func test_partialCallbackFired() async throws {
        let expectation = expectation(description: "partial")
        var receivedPartial: ASRPartial?

        manager.onPartial = { partial in
            receivedPartial = partial
            expectation.fulfill()
        }

        mockEngine.mockTranscription = "Hello world"

        // Add audio to buffer
        let samples = [Float](repeating: 0.1, count: 16000)
        ringBuffer.append(samples)

        try await manager.start()

        await fulfillment(of: [expectation], timeout: 1.0)
        await manager.stop()

        XCTAssertNotNil(receivedPartial)
        XCTAssertEqual(receivedPartial?.text, "Hello world")
    }

    /// TC-5.2: Final callback on force finalize
    func test_finalCallbackOnForceFinalize() async throws {
        let expectation = expectation(description: "final")
        var receivedFinal: ASRFinalSegment?

        manager.onFinal = { segment in
            receivedFinal = segment
            expectation.fulfill()
        }

        mockEngine.mockTranscription = "Test transcription"

        let samples = [Float](repeating: 0.1, count: 16000)
        ringBuffer.append(samples)

        try await manager.start()

        // Wait for partial processing
        try await Task.sleep(nanoseconds: 200_000_000)

        // Force finalize
        await manager.forceFinalize()

        await fulfillment(of: [expectation], timeout: 1.0)
        await manager.stop()

        XCTAssertNotNil(receivedFinal)
        XCTAssertEqual(receivedFinal?.text, "Test transcription")
    }

    /// TC-5.4: Start when already streaming throws
    func test_startWhenStreamingThrows() async throws {
        let samples = [Float](repeating: 0.1, count: 16000)
        ringBuffer.append(samples)

        try await manager.start()

        do {
            try await manager.start()
            XCTFail("Should have thrown")
        } catch StreamingError.alreadyStreaming {
            // Expected
        }

        await manager.stop()
    }

    /// TC-5.5: Stop when not streaming is safe
    func test_stopWhenNotStreamingSafe() async {
        await manager.stop()  // Should not crash
    }

    // MARK: - State Tracking

    func test_isStreamingState() async throws {
        XCTAssertFalse(manager.isStreaming, "Should not be streaming initially")

        let samples = [Float](repeating: 0.1, count: 16000)
        ringBuffer.append(samples)

        try await manager.start()
        XCTAssertTrue(manager.isStreaming, "Should be streaming after start")

        await manager.stop()
        XCTAssertFalse(manager.isStreaming, "Should not be streaming after stop")
    }

    // MARK: - VAD Integration

    func test_vadGatingReducesProcessing() async throws {
        var config = StreamingConfiguration()
        config.hopInterval = 0.05
        config.enableVAD = true
        config.minimumAudioLength = 0.1

        let vadManager = StreamingManager(
            configuration: config,
            engine: mockEngine,
            ringBuffer: ringBuffer
        )

        var partialCount = 0
        vadManager.onPartial = { _ in partialCount += 1 }

        // Write silent audio (very low amplitude)
        let silentSamples = [Float](repeating: 0.0001, count: 16000)
        ringBuffer.append(silentSamples)

        try await vadManager.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await vadManager.stop()

        // Should have fewer partials due to VAD gating
        XCTAssertLessThan(partialCount, 5, "VAD should reduce processing during silence")
    }

    func test_vadStateChangeCallback() async throws {
        var config = StreamingConfiguration()
        config.hopInterval = 0.1
        config.enableVAD = true
        config.minimumAudioLength = 0.1

        let vadManager = StreamingManager(
            configuration: config,
            engine: mockEngine,
            ringBuffer: ringBuffer
        )

        let expectation = expectation(description: "vadChange")
        var vadStates: [Bool] = []

        vadManager.onVADStateChange = { isSpeech in
            vadStates.append(isSpeech)
            if vadStates.count >= 1 {
                expectation.fulfill()
            }
        }

        mockEngine.mockTranscription = "Hello"

        // Write loud audio
        let loudSamples = [Float](repeating: 0.5, count: 16000)
        ringBuffer.append(loudSamples)

        try await vadManager.start()

        await fulfillment(of: [expectation], timeout: 1.0)
        await vadManager.stop()

        // Should have received at least one VAD state change
        XCTAssertFalse(vadStates.isEmpty)
    }

    // MARK: - Error Handling

    func test_errorCallbackOnTranscriptionFailure() async throws {
        // Create a failing engine
        final class FailingEngine: @unchecked Sendable, ASREngine {
            func prepare() async throws {}
            func reset() async {}
            func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {}
            func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
                throw NSError(domain: "test", code: 1)
            }
            func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
                return nil
            }
        }

        var config = StreamingConfiguration()
        config.hopInterval = 0.1
        config.enableVAD = false
        config.minimumAudioLength = 0.1

        let failingManager = StreamingManager(
            configuration: config,
            engine: FailingEngine(),
            ringBuffer: ringBuffer
        )

        let expectation = expectation(description: "error")
        var receivedError: StreamingError?

        failingManager.onError = { error in
            receivedError = error
            expectation.fulfill()
        }

        let samples = [Float](repeating: 0.1, count: 16000)
        ringBuffer.append(samples)

        try await failingManager.start()

        await fulfillment(of: [expectation], timeout: 1.0)
        await failingManager.stop()

        XCTAssertNotNil(receivedError)
        if case .transcriptionFailed = receivedError! {
            // Expected
        } else {
            XCTFail("Expected transcriptionFailed error")
        }
    }

    // MARK: - Minimum Audio Length

    func test_minimumAudioLengthRespected() async throws {
        var config = StreamingConfiguration()
        config.hopInterval = 0.05
        config.enableVAD = false
        config.minimumAudioLength = 1.0  // Require 1 second

        let strictManager = StreamingManager(
            configuration: config,
            engine: mockEngine,
            ringBuffer: ringBuffer
        )

        var partialCount = 0
        strictManager.onPartial = { _ in partialCount += 1 }

        mockEngine.mockTranscription = "Hello"

        // Write only 0.5 seconds of audio
        let samples = [Float](repeating: 0.1, count: 8000)
        ringBuffer.append(samples)

        try await strictManager.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await strictManager.stop()

        // Should have no partials (not enough audio)
        XCTAssertEqual(partialCount, 0, "Should not process with insufficient audio")
    }
}
