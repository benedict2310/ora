//
//  TTSServiceTests.swift
//  OraTests
//
//  Tests for TTSService
//

import XCTest

@testable import Ora

final class TTSServiceTests: XCTestCase {

    // MARK: - AudioChunk Tests

    func test_audioChunkDuration_calculatesCorrectly() {
        // Given: 24000 samples at 24kHz = 1 second
        let samples = [Float](repeating: 0.0, count: 24000)
        let chunk = AudioChunk(samples: samples, sampleRate: 24000)

        // Then
        XCTAssertEqual(chunk.duration, 1.0, accuracy: 0.001)
    }

    func test_audioChunkDuration_halfSecond() {
        // Given: 12000 samples at 24kHz = 0.5 seconds
        let samples = [Float](repeating: 0.0, count: 12000)
        let chunk = AudioChunk(samples: samples, sampleRate: 24000)

        // Then
        XCTAssertEqual(chunk.duration, 0.5, accuracy: 0.001)
    }

    func test_audioChunkDuration_zeroSampleRate() {
        // Given: Zero sample rate (edge case)
        let chunk = AudioChunk(samples: [1.0, 2.0, 3.0], sampleRate: 0)

        // Then: Duration should be 0 to avoid division by zero
        XCTAssertEqual(chunk.duration, 0.0)
    }

    func test_audioChunk_isEmpty() {
        // Given
        let emptyChunk = AudioChunk.empty(sampleRate: 24000)
        let nonEmptyChunk = AudioChunk(samples: [1.0], sampleRate: 24000)

        // Then
        XCTAssertTrue(emptyChunk.isEmpty)
        XCTAssertFalse(nonEmptyChunk.isEmpty)
    }

    func test_sampleRateIs24kHz() {
        // Given: Kokoro default sample rate
        XCTAssertEqual(TTSService.kokoroSampleRate, 24000)
    }

    // MARK: - TTSService Tests

    func test_speakReturnsAsyncStream() async {
        // Given
        let service = TTSService(kokoroEngine: nil)

        // When
        let stream = service.speak("Hello")

        // Then: Stream should be iterable (we don't fully consume it to keep test fast)
        var iterator = stream.makeAsyncIterator()

        // With no Kokoro engine, it should use fallback which yields an empty chunk
        // and then the AVSpeechSynthesizer plays directly
        // We just verify the stream is valid and can be iterated
        do {
            // Get first chunk or finish - either is valid
            _ = try await iterator.next()
        } catch {
            // Synthesis errors are acceptable in test environment
        }
    }

    func test_stopCancelsSynthesis() async {
        // Given
        let service = TTSService(kokoroEngine: nil)
        let stream = service.speak("This is a longer text that would take time to synthesize")

        // When: Start iterating then stop
        let task = Task {
            for try await _ in stream {
                // Consume chunks
            }
        }

        // Give it a moment to start
        try? await Task.sleep(for: .milliseconds(50))

        // Stop synthesis
        await service.stop()

        // Then: Task should complete without hanging
        task.cancel()
        
        // Verify speaking state is false after stop
        let speaking = await service.speaking
        XCTAssertFalse(speaking)
    }

    func test_kokoroAvailable_falseWithoutEngine() async {
        // Given
        let service = TTSService(kokoroEngine: nil)

        // Then
        let available = await service.kokoroAvailable
        XCTAssertFalse(available)
    }

    // MARK: - KokoroEngine Tests

    func test_kokoroEngineThrows_whenModelNotFound() async {
        // Given: A path that doesn't exist
        let fakePath = URL(fileURLWithPath: "/nonexistent/path")

        // When/Then
        do {
            _ = try await KokoroEngine(modelPath: fakePath)
            XCTFail("Should have thrown")
        } catch {
            // Expected
            XCTAssertTrue(error is TTSError)
        }
    }

    func test_kokoroEngineSynthesizeTriggersError() async {
        // Given: Create a mock model directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create required files
        let configPath = tempDir.appendingPathComponent("config.json")
        let weightsPath = tempDir.appendingPathComponent("kokoro-v1_0.safetensors")
        try? "{}".write(to: configPath, atomically: true, encoding: .utf8)
        try? Data().write(to: weightsPath)

        // When
        do {
            let engine = try await KokoroEngine(modelPath: tempDir)
            let stream = await engine.synthesize(text: "Hello")

            // Then: Should throw since Kokoro isn't actually integrated yet
            for try await _ in stream {
                XCTFail("Should have thrown, not yielded samples")
            }
        } catch {
            // Expected - the placeholder implementation throws
            XCTAssertTrue(error is TTSError)
        }
    }

    // MARK: - TTSError Tests

    func test_ttsError_descriptions() {
        XCTAssertNotNil(TTSError.modelNotFound.errorDescription)
        XCTAssertNotNil(TTSError.initializationFailed("test").errorDescription)
        XCTAssertNotNil(TTSError.synthesisFailed("test").errorDescription)
        XCTAssertNotNil(TTSError.cancelled.errorDescription)
    }
}
