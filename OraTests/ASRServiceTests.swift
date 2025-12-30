//
//  ASRServiceTests.swift
//  OraTests
//
//  Unit tests for ASRService and related types.
//

import XCTest
import AVFoundation
@testable import Ora

// MARK: - ASREvent Tests

final class ASREventTests: XCTestCase {

    // MARK: - Sendable Tests

    func test_partialEvent_isSendable() async {
        let event = ASREvent.partial(text: "hello", stability: 0.8)

        let result = await Task.detached {
            return event
        }.value

        if case .partial(let text, let stability) = result {
            XCTAssertEqual(text, "hello")
            XCTAssertEqual(stability, 0.8)
        } else {
            XCTFail("Expected partial event")
        }
    }

    func test_finalEvent_isSendable() async {
        let event = ASREvent.final(text: "hello world")

        let result = await Task.detached {
            return event
        }.value

        if case .final(let text) = result {
            XCTAssertEqual(text, "hello world")
        } else {
            XCTFail("Expected final event")
        }
    }

    // MARK: - Equatable Tests

    func test_partialEvents_areEquatable() {
        let event1 = ASREvent.partial(text: "hello", stability: 0.8)
        let event2 = ASREvent.partial(text: "hello", stability: 0.8)
        let event3 = ASREvent.partial(text: "world", stability: 0.8)
        let event4 = ASREvent.partial(text: "hello", stability: 0.5)

        XCTAssertEqual(event1, event2)
        XCTAssertNotEqual(event1, event3)
        XCTAssertNotEqual(event1, event4)
    }

    func test_finalEvents_areEquatable() {
        let event1 = ASREvent.final(text: "hello")
        let event2 = ASREvent.final(text: "hello")
        let event3 = ASREvent.final(text: "world")

        XCTAssertEqual(event1, event2)
        XCTAssertNotEqual(event1, event3)
    }

    func test_differentEventTypes_areNotEqual() {
        let partial = ASREvent.partial(text: "hello", stability: 0.8)
        let final = ASREvent.final(text: "hello")

        XCTAssertNotEqual(partial, final)
    }
}

// MARK: - ASRServiceError Tests

final class ASRServiceErrorTests: XCTestCase {

    func test_notReady_description() {
        let error = ASRServiceError.notReady
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not ready"))
    }

    func test_transcriptionFailed_description() {
        let error = ASRServiceError.transcriptionFailed("test failure")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("test failure"))
    }
}

// MARK: - ASR Service Mock Engine

/// Mock ASR engine for testing ASRService (named differently to avoid conflict with StreamingManagerTests)
final class ASRServiceTestEngine: ASREngine, @unchecked Sendable {
    var prepareCallCount = 0
    var processCallCount = 0
    var finalizeCallCount = 0
    var resetCallCount = 0

    var processResult: ASRPartial?
    var finalizeResult: ASRFinalSegment?
    var shouldThrowOnProcess = false
    var shouldThrowOnFinalize = false

    private var partialHandler: (@Sendable (ASRPartial) -> Void)?

    func prepare() async throws {
        prepareCallCount += 1
    }

    func reset() async {
        resetCallCount += 1
    }

    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {
        partialHandler = handler
    }

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        processCallCount += 1
        if shouldThrowOnProcess {
            throw NSError(domain: "MockASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock process error"])
        }
        if let result = processResult {
            partialHandler?(result)
        }
        return processResult
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        finalizeCallCount += 1
        if shouldThrowOnFinalize {
            throw NSError(domain: "MockASR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mock finalize error"])
        }
        return finalizeResult
    }
}

// MARK: - ASRService Tests

final class ASRServiceTests: XCTestCase {

    // MARK: - AC-1: Protocol Conformance

    func test_asrService_conformsToASRServicing() {
        let mockEngine = ASRServiceTestEngine()
        let service = ASRService(engine: mockEngine)

        // Verify type conforms to protocol by assigning to protocol type
        let _: any ASRServicing = service
        XCTAssertNotNil(service)
    }

    // MARK: - AC-2: transcribe() Returns Correct Type

    func test_transcribe_returnsAsyncThrowingStream() async throws {
        let mockEngine = ASRServiceTestEngine()
        mockEngine.processResult = ASRPartial(text: "test", words: [])
        mockEngine.finalizeResult = ASRFinalSegment(text: "test", words: [])

        let service = ASRService(engine: mockEngine)
        try await service.prepare()

        // Create a simple frame stream
        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()

        // Get the transcription stream
        let eventStream = await service.transcribe(frames: stream)

        // Finish immediately
        continuation.finish()

        // The type should be AsyncThrowingStream<ASREvent, Error>
        var events: [ASREvent] = []
        do {
            for try await event in eventStream {
                events.append(event)
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // With empty input, we should get no events
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - AC-3: Partial Events Emitted

    func test_transcribe_emitsPartialEvents() async throws {
        let mockEngine = ASRServiceTestEngine()
        mockEngine.processResult = ASRPartial(text: "hello", words: [])
        mockEngine.finalizeResult = ASRFinalSegment(text: "hello world", words: [])

        let service = ASRService(engine: mockEngine)
        try await service.prepare()

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()

        let eventStream = await service.transcribe(frames: stream)

        // Send enough samples to trigger processing (2560 = 160ms at 16kHz)
        let samples = Array(repeating: Float(0.1), count: 2560)
        continuation.yield(AudioFrame(samples: samples))
        continuation.finish()

        var events: [ASREvent] = []
        for try await event in eventStream {
            events.append(event)
        }

        // Should have at least one partial event
        let partialEvents = events.filter {
            if case .partial = $0 { return true }
            return false
        }
        XCTAssertFalse(partialEvents.isEmpty, "Expected at least one partial event")
    }

    // MARK: - AC-4: Final Event Emitted

    func test_transcribe_emitsFinalEvent() async throws {
        let mockEngine = ASRServiceTestEngine()
        mockEngine.processResult = ASRPartial(text: "hello", words: [])
        mockEngine.finalizeResult = ASRFinalSegment(text: "hello world", words: [])

        let service = ASRService(engine: mockEngine)
        try await service.prepare()

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()

        let eventStream = await service.transcribe(frames: stream)

        // Send audio
        let samples = Array(repeating: Float(0.1), count: 2560)
        continuation.yield(AudioFrame(samples: samples))
        continuation.finish()

        var events: [ASREvent] = []
        for try await event in eventStream {
            events.append(event)
        }

        // Should have a final event
        let finalEvents = events.filter {
            if case .final = $0 { return true }
            return false
        }
        XCTAssertEqual(finalEvents.count, 1, "Expected exactly one final event")

        if case .final(let text) = finalEvents.first {
            XCTAssertEqual(text, "hello world")
        }
    }

    // MARK: - AC-5: Reset Clears State

    func test_reset_callsEngineReset() async throws {
        let mockEngine = ASRServiceTestEngine()
        let service = ASRService(engine: mockEngine)

        await service.reset()

        XCTAssertEqual(mockEngine.resetCallCount, 1)
    }

    // MARK: - AC-6: Handles Empty Audio

    func test_transcribe_handlesEmptyAudioGracefully() async throws {
        let mockEngine = ASRServiceTestEngine()
        let service = ASRService(engine: mockEngine)
        try await service.prepare()

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()

        let eventStream = await service.transcribe(frames: stream)

        // Finish immediately without sending any frames
        continuation.finish()

        var events: [ASREvent] = []
        do {
            for try await event in eventStream {
                events.append(event)
            }
        } catch {
            XCTFail("Should not throw for empty audio: \(error)")
        }

        // Empty audio should produce no events (not an error)
        XCTAssertTrue(events.isEmpty)
    }

    func test_transcribe_handlesEmptyFrames() async throws {
        let mockEngine = ASRServiceTestEngine()
        let service = ASRService(engine: mockEngine)
        try await service.prepare()

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()

        let eventStream = await service.transcribe(frames: stream)

        // Send empty frames
        continuation.yield(AudioFrame(samples: []))
        continuation.yield(AudioFrame(samples: []))
        continuation.finish()

        var events: [ASREvent] = []
        do {
            for try await event in eventStream {
                events.append(event)
            }
        } catch {
            XCTFail("Should not throw for empty frames: \(error)")
        }

        // Empty frames should produce no events
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Engine Readiness Tests

    func test_transcribe_throwsWhenNotPrepared() async {
        let mockEngine = ASRServiceTestEngine()
        let service = ASRService(engine: mockEngine)
        // Note: NOT calling prepare()

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()

        let eventStream = await service.transcribe(frames: stream)

        // Send some audio
        let samples = Array(repeating: Float(0.1), count: 2560)
        continuation.yield(AudioFrame(samples: samples))
        continuation.finish()

        var caughtExpectedError = false
        do {
            for try await _ in eventStream {
                XCTFail("Should throw when not prepared")
            }
            XCTFail("Should throw when not prepared")
        } catch let error as ASRServiceError {
            if case .notReady = error {
                caughtExpectedError = true
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertTrue(caughtExpectedError, "Should throw notReady error")
    }

    func test_prepare_canBeCalledMultipleTimes() async throws {
        let mockEngine = ASRServiceTestEngine()
        let service = ASRService(engine: mockEngine)

        try await service.prepare()
        try await service.prepare()
        try await service.prepare()

        // Should only prepare once
        XCTAssertEqual(mockEngine.prepareCallCount, 1)
    }

    // MARK: - Partial Deduplication Tests

    func test_transcribe_deduplicatesIdenticalPartials() async throws {
        let mockEngine = ASRServiceTestEngine()
        // Return the same text multiple times
        mockEngine.processResult = ASRPartial(text: "same text", words: [])
        mockEngine.finalizeResult = ASRFinalSegment(text: "same text", words: [])

        let service = ASRService(engine: mockEngine)
        try await service.prepare()

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()

        let eventStream = await service.transcribe(frames: stream)

        // Send multiple frames that would all produce the same text
        let samples = Array(repeating: Float(0.1), count: 2560)
        continuation.yield(AudioFrame(samples: samples))
        continuation.yield(AudioFrame(samples: samples))
        continuation.yield(AudioFrame(samples: samples))
        continuation.finish()

        var partialEvents: [ASREvent] = []
        for try await event in eventStream {
            if case .partial = event {
                partialEvents.append(event)
            }
        }

        // Should only emit one partial since the text is the same
        XCTAssertEqual(partialEvents.count, 1, "Identical partials should be deduplicated")
    }

    // MARK: - Shared Instance Tests

    func test_shared_instance_exists() {
        let service = ASRService.shared
        XCTAssertNotNil(service)
    }
}
