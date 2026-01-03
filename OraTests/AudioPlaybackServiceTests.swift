//
//  AudioPlaybackServiceTests.swift
//  OraTests
//
//  Tests for AudioPlaybackService
//

import XCTest

@testable import Ora

final class AudioPlaybackServiceTests: XCTestCase {

    // MARK: - Prepare Tests

    func test_prepareInitializesEngine() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        
        // When
        try await service.prepare()
        
        // Then
        let isPrepared = await service.isPrepared
        XCTAssertTrue(isPrepared)
    }

    func test_prepareIsIdempotent() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        
        // When: Call prepare multiple times
        try await service.prepare()
        try await service.prepare()
        try await service.prepare()
        
        // Then: Should succeed without error
        let isPrepared = await service.isPrepared
        XCTAssertTrue(isPrepared)
    }

    func test_isPrepared_falseInitially() async {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        
        // Then
        let isPrepared = await service.isPrepared
        XCTAssertFalse(isPrepared)
    }

    // MARK: - Play Tests

    func test_playThrowsWhenNotPrepared() async {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        let emptyStream = AsyncThrowingStream<AudioChunk, Error> { $0.finish() }
        
        // When/Then
        do {
            try await service.play(chunks: emptyStream)
            XCTFail("Should have thrown")
        } catch let error as AudioPlaybackError {
            XCTAssertEqual(error.errorDescription, "Audio playback not prepared. Call prepare() first.")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_playEmptyChunksSkipped() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        try await service.prepare()
        
        // Create stream with only empty chunks
        let stream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk.empty(sampleRate: 24000))
            continuation.yield(AudioChunk.empty(sampleRate: 24000))
            continuation.finish()
        }
        
        // When
        try await service.play(chunks: stream)
        
        // Then: Should complete without error
        let playing = await service.playing
        XCTAssertFalse(playing)
    }

    func test_playStreamsChunks() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        try await service.prepare()
        
        // Create stream with audio chunks
        let samples = [Float](repeating: 0.0, count: 2400)  // 100ms at 24kHz
        let stream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for _ in 0..<3 {
                continuation.yield(AudioChunk(samples: samples, sampleRate: 24000))
            }
            continuation.finish()
        }
        
        // When
        try await service.play(chunks: stream)
        
        // Then: Should complete without error
        let playing = await service.playing
        XCTAssertFalse(playing)
    }

    // MARK: - Stop Tests

    func test_stopClearsQueue() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        try await service.prepare()
        
        // Create a slow stream
        let stream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            let samples = [Float](repeating: 0.0, count: 24000)  // 1s at 24kHz
            for _ in 0..<10 {
                continuation.yield(AudioChunk(samples: samples, sampleRate: 24000))
            }
            // Don't finish - simulate long playback
        }
        
        // Start playback in background
        let playTask = Task {
            try await service.play(chunks: stream)
        }
        
        // Give it time to start
        try? await Task.sleep(for: .milliseconds(100))
        
        // When
        await service.stop()
        
        // Then
        let playing = await service.playing
        XCTAssertFalse(playing)
        
        // Cleanup
        playTask.cancel()
    }

    func test_stopIsIdempotent() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        try await service.prepare()
        
        // When: Stop multiple times without playing
        await service.stop()
        await service.stop()
        await service.stop()
        
        // Then: Should not throw or crash
        let playing = await service.playing
        XCTAssertFalse(playing)
    }

    // MARK: - Shutdown Tests

    func test_shutdownCleansUp() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        try await service.prepare()
        
        // Verify prepared
        var isPrepared = await service.isPrepared
        XCTAssertTrue(isPrepared)
        
        // When
        await service.shutdown()
        
        // Then
        isPrepared = await service.isPrepared
        XCTAssertFalse(isPrepared)
    }

    // MARK: - Error Tests

    func test_audioPlaybackError_descriptions() {
        XCTAssertNotNil(AudioPlaybackError.notPrepared.errorDescription)
        XCTAssertNotNil(AudioPlaybackError.engineStartFailed("test").errorDescription)
    }

    // MARK: - State Tests

    func test_playingState_duringPlayback() async throws {
        // Given
        let service = AudioPlaybackService(engine: nil, playerNode: nil)
        try await service.prepare()
        
        // Initially not playing
        var playing = await service.playing
        XCTAssertFalse(playing)
        
        // Create a stream that we control
        var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
        let stream = AsyncThrowingStream<AudioChunk, Error> { cont in
            continuation = cont
        }
        
        // Start playback in background
        let playTask = Task {
            try await service.play(chunks: stream)
        }
        
        // Give it time to start
        try? await Task.sleep(for: .milliseconds(50))
        
        // During playback, should be playing
        playing = await service.playing
        XCTAssertTrue(playing)
        
        // Finish stream
        continuation?.finish()
        
        // Wait for completion
        try? await playTask.value
        
        // After completion, should not be playing
        playing = await service.playing
        XCTAssertFalse(playing)
    }
}
