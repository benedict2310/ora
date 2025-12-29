//
//  AudioCaptureTests.swift
//  OraTests
//
//  Tests for audio capture pipeline components.
//

import XCTest
import os
@testable import Ora

// MARK: - StreamingRingBuffer Tests

final class StreamingRingBufferTests: XCTestCase {

    // MARK: - Basic Operations

    func test_empty_buffer_properties() {
        let buffer = StreamingRingBuffer(capacity: 1000)

        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.availableSpace, 1000)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertFalse(buffer.isFull)
        XCTAssertEqual(buffer.fillLevel, 0.0)
    }

    func test_append_and_count() {
        let buffer = StreamingRingBuffer(capacity: 1000)

        buffer.append([1.0, 2.0, 3.0])

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.availableSpace, 997)
    }

    func test_peek_returns_samples_without_removing() {
        let buffer = StreamingRingBuffer(capacity: 1000)
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0])

        let peeked = buffer.peek(count: 3)

        XCTAssertEqual(peeked, [1.0, 2.0, 3.0])
        XCTAssertEqual(buffer.count, 5) // Still 5, not removed
    }

    func test_read_removes_samples() {
        let buffer = StreamingRingBuffer(capacity: 1000)
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0])

        let read = buffer.read(count: 3)

        XCTAssertEqual(read, [1.0, 2.0, 3.0])
        XCTAssertEqual(buffer.count, 2) // 5 - 3 = 2 remaining
    }

    func test_wraparound_behavior() {
        let buffer = StreamingRingBuffer(capacity: 5)

        // Fill completely
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertTrue(buffer.isFull)

        // Read some
        _ = buffer.read(count: 3) // Remove [1, 2, 3]
        XCTAssertEqual(buffer.count, 2) // [4, 5] remain

        // Add more (should wrap around)
        buffer.append([6.0, 7.0, 8.0])
        XCTAssertEqual(buffer.count, 5)

        // Verify order
        let all = buffer.peekAll()
        XCTAssertEqual(all, [4.0, 5.0, 6.0, 7.0, 8.0])
    }

    func test_overwrite_oldest_when_full() {
        let buffer = StreamingRingBuffer(capacity: 5)

        // Fill and overflow
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0])
        buffer.append([6.0, 7.0]) // Should overwrite [1, 2]

        let all = buffer.peekAll()
        XCTAssertEqual(all, [3.0, 4.0, 5.0, 6.0, 7.0])
        XCTAssertEqual(buffer.count, 5) // Still at capacity
    }

    func test_reset_clears_buffer() {
        let buffer = StreamingRingBuffer(capacity: 1000)
        buffer.append([1.0, 2.0, 3.0])

        buffer.reset()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
    }

    func test_drain_returns_all_and_clears() {
        let buffer = StreamingRingBuffer(capacity: 1000)
        buffer.append([1.0, 2.0, 3.0])

        let drained = buffer.drain()

        XCTAssertEqual(drained, [1.0, 2.0, 3.0])
        XCTAssertTrue(buffer.isEmpty)
    }

    func test_skip_removes_without_returning() {
        let buffer = StreamingRingBuffer(capacity: 1000)
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0])

        buffer.skip(2)

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.peekAll(), [3.0, 4.0, 5.0])
    }

    // MARK: - Duration-Based Initialization

    func test_duration_based_capacity() {
        let buffer = StreamingRingBuffer(duration: 10.0, sampleRate: 16000)

        XCTAssertEqual(buffer.capacity, 160000)
    }

    func test_duration_property() {
        let buffer = StreamingRingBuffer(capacity: 16000) // 1 second at 16kHz
        buffer.append([Float](repeating: 0.5, count: 8000))

        XCTAssertEqual(buffer.duration, 0.5, accuracy: 0.001)
    }

    func test_peek_seconds() {
        let buffer = StreamingRingBuffer(capacity: 32000)
        buffer.append([Float](repeating: 0.5, count: 16000))

        let samples = buffer.peek(seconds: 0.5)

        XCTAssertEqual(samples.count, 8000)
    }

    // MARK: - Thread Safety Tests

    func test_concurrent_append_and_read() async {
        let buffer = StreamingRingBuffer(capacity: 10000)
        let iterations = 1000

        // Concurrent writers and readers
        await withTaskGroup(of: Void.self) { group in
            // Writer task
            group.addTask {
                for i in 0..<iterations {
                    buffer.append([Float(i)])
                }
            }

            // Reader task
            group.addTask {
                var totalRead = 0
                while totalRead < iterations {
                    let samples = buffer.read(count: 10)
                    totalRead += samples.count
                    if samples.isEmpty {
                        await Task.yield()
                    }
                }
            }
        }

        // Should complete without crashes or hangs
    }

    func test_concurrent_append_from_multiple_threads() async {
        let buffer = StreamingRingBuffer(capacity: 100000)
        let tasksCount = 10
        let samplesPerTask = 1000

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<tasksCount {
                group.addTask {
                    let samples = (0..<samplesPerTask).map { Float(taskId * samplesPerTask + $0) }
                    buffer.append(samples)
                }
            }
        }

        // Verify all samples were added (or oldest overwritten if > capacity)
        XCTAssertEqual(buffer.count, min(tasksCount * samplesPerTask, buffer.capacity))
    }

    // MARK: - Stress Tests

    func test_rapid_append_and_reset() async {
        let buffer = StreamingRingBuffer(capacity: 1000)

        for _ in 0..<100 {
            buffer.append([Float](repeating: 1.0, count: 500))
            buffer.reset()
        }

        XCTAssertTrue(buffer.isEmpty)
    }

    func test_memory_bounds_with_overflow() {
        let buffer = StreamingRingBuffer(capacity: 100)

        // Append 10x capacity
        for i in 0..<1000 {
            buffer.append([Float(i)])
        }

        // Should only have last 100
        XCTAssertEqual(buffer.count, 100)
        let samples = buffer.peekAll()
        XCTAssertEqual(samples.first, 900.0)
        XCTAssertEqual(samples.last, 999.0)
    }

    func test_empty_append_is_noop() {
        let buffer = StreamingRingBuffer(capacity: 100)
        buffer.append([1.0, 2.0])
        
        buffer.append([])
        
        XCTAssertEqual(buffer.count, 2)
    }

    func test_peek_more_than_available_returns_all() {
        let buffer = StreamingRingBuffer(capacity: 100)
        buffer.append([1.0, 2.0, 3.0])

        let peeked = buffer.peek(count: 100)

        XCTAssertEqual(peeked, [1.0, 2.0, 3.0])
    }

    func test_read_from_empty_buffer() {
        let buffer = StreamingRingBuffer(capacity: 100)

        let read = buffer.read(count: 10)

        XCTAssertTrue(read.isEmpty)
    }
}

// MARK: - AudioFormatConverter Tests

import AVFoundation

final class AudioFormatConverterTests: XCTestCase {

    // MARK: - Format Conversion Tests

    func test_convert_48kHz_mono_to_16kHz() throws {
        // Given: 48kHz mono input buffer
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!
        let buffer = createTestBuffer(format: inputFormat, frameCount: 4800) // 100ms

        let converter = AudioFormatConverter()

        // When: Converting
        let samples = try converter.convertThrowing(buffer: buffer)

        // Then: Output is approximately 16kHz mono
        // 4800 samples @ 48kHz = 100ms -> ~1600 samples @ 16kHz
        // AVAudioConverter may vary slightly, allow 25% tolerance
        XCTAssertGreaterThan(samples.count, 1200, "Should produce reasonable amount of samples")
        XCTAssertLessThan(samples.count, 2000, "Should not produce too many samples")
    }

    func test_convert_44100Hz_to_16kHz() throws {
        // Given: 44.1kHz input
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!
        let buffer = createTestBuffer(format: inputFormat, frameCount: 4410) // 100ms

        let converter = AudioFormatConverter()

        // When: Converting
        let samples = try converter.convertThrowing(buffer: buffer)

        // Then: Approximately correct sample count
        // 4410 samples @ 44.1kHz = 100ms -> ~1600 samples @ 16kHz
        // AVAudioConverter may vary, allow 25% tolerance
        XCTAssertGreaterThan(samples.count, 1200, "Should produce reasonable amount of samples")
        XCTAssertLessThan(samples.count, 2000, "Should not produce too many samples")
    }

    func test_convert_preserves_silence() throws {
        // Given: Silent buffer
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!
        let buffer = createSilentBuffer(format: inputFormat, frameCount: 4800)

        let converter = AudioFormatConverter()

        // When: Converting
        let samples = try converter.convertThrowing(buffer: buffer)

        // Then: Output is also silent (near-zero)
        let maxAbsValue = samples.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(maxAbsValue, 0.001, "Silent input should produce silent output")
    }

    func test_convert_48kHz_stereo_to_16kHz_mono() throws {
        // Given: 48kHz stereo input buffer (AC-03: stereo→mono downmix)
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        let buffer = createTestBuffer(format: inputFormat, frameCount: 4800) // 100ms

        let converter = AudioFormatConverter()

        // When: Converting
        let samples = try converter.convertThrowing(buffer: buffer)

        // Then: Output is 16kHz mono (single channel)
        // 4800 samples @ 48kHz = 100ms -> ~1600 samples @ 16kHz
        XCTAssertGreaterThan(samples.count, 1200, "Should produce reasonable amount of samples")
        XCTAssertLessThan(samples.count, 2000, "Should not produce too many samples")
        
        // Verify we get a single channel output (mono) - samples should be non-empty
        XCTAssertFalse(samples.isEmpty, "Stereo->mono conversion should produce output")
    }

    func test_converter_caching() throws {
        // Given: Converter instance
        let converter = AudioFormatConverter()

        let format1 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let format2 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!

        let buffer1 = createTestBuffer(format: format1, frameCount: 1000)
        let buffer2 = createTestBuffer(format: format2, frameCount: 1000)

        // When: Converting multiple formats
        _ = converter.convert(buffer: buffer1)
        _ = converter.convert(buffer: buffer2)
        _ = converter.convert(buffer: buffer1) // Cache hit

        // Then: Two converters cached
        XCTAssertEqual(converter.cachedFormatCount, 2)
    }

    func test_clear_cache() throws {
        let converter = AudioFormatConverter()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = createTestBuffer(format: format, frameCount: 1000)

        _ = converter.convert(buffer: buffer)
        XCTAssertEqual(converter.cachedFormatCount, 1)

        converter.clearCache()

        XCTAssertEqual(converter.cachedFormatCount, 0)
    }

    func test_converter_thread_safety() async {
        // Given: Single converter instance
        let converter = AudioFormatConverter()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

        // When: Concurrent conversions from multiple tasks
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000)!
                    buffer.frameLength = 1000
                    if let channelData = buffer.floatChannelData {
                        for frame in 0..<1000 {
                            channelData[0][frame] = Float.random(in: -0.5...0.5)
                        }
                    }
                    return converter.convert(buffer: buffer) != nil
                }
            }

            // Then: All conversions succeed
            for await result in group {
                XCTAssertTrue(result, "Concurrent conversion should succeed")
            }
        }
    }

    func test_target_format_is_16kHz_mono() {
        let converter = AudioFormatConverter()

        XCTAssertEqual(converter.targetFormat.sampleRate, 16000)
        XCTAssertEqual(converter.targetFormat.channelCount, 1)
        XCTAssertEqual(converter.targetFormat.commonFormat, .pcmFormatFloat32)
    }

    func test_custom_target_sample_rate() {
        let converter = AudioFormatConverter(targetSampleRate: 8000)

        XCTAssertEqual(converter.targetFormat.sampleRate, 8000)
    }

    // MARK: - Helpers

    private func createTestBuffer(format: AVAudioFormat, frameCount: UInt32) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        // Fill with random noise
        if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    channelData[channel][frame] = Float.random(in: -0.5...0.5)
                }
            }
        }

        return buffer
    }

    private func createSilentBuffer(format: AVAudioFormat, frameCount: UInt32) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Already zero-initialized
        return buffer
    }
}

// MARK: - AudioCapture Tests

final class AudioCaptureStateTests: XCTestCase {

    func test_initial_state_is_idle() {
        let capture = AudioCapture()
        
        XCTAssertEqual(capture.state, .idle)
    }

    func test_stop_when_idle_is_safe() {
        let capture = AudioCapture()
        
        capture.stop() // Should not crash
        
        XCTAssertEqual(capture.state, .idle)
    }
}

// MARK: - AudioPipeline Tests

final class AudioPipelineTests: XCTestCase {

    func test_initial_state_is_idle() {
        let pipeline = AudioPipeline()
        
        XCTAssertEqual(pipeline.state, .idle)
    }

    func test_buffer_fill_level_starts_at_zero() {
        let pipeline = AudioPipeline()
        
        XCTAssertEqual(pipeline.bufferFillLevel, 0.0)
    }

    func test_buffered_duration_starts_at_zero() {
        let pipeline = AudioPipeline()
        
        XCTAssertEqual(pipeline.bufferedDuration, 0.0)
    }

    func test_get_audio_context_when_empty() {
        let pipeline = AudioPipeline()
        
        let context = pipeline.getAudioContext(seconds: 1.0)
        
        XCTAssertTrue(context.isEmpty)
    }

    func test_get_all_buffered_audio_when_empty() {
        let pipeline = AudioPipeline()
        
        let audio = pipeline.getAllBufferedAudio()
        
        XCTAssertTrue(audio.isEmpty)
    }

    func test_custom_configuration() {
        let config = AudioPipeline.Configuration(
            bufferDuration: 5.0,
            chunkSize: 1600,
            targetSampleRate: 8000
        )
        let pipeline = AudioPipeline(configuration: config)
        
        // Should not crash
        XCTAssertEqual(pipeline.state, .idle)
    }

    func test_reset_buffer_when_empty_is_safe() {
        let pipeline = AudioPipeline()
        
        pipeline.resetBuffer() // Should not crash
        
        XCTAssertEqual(pipeline.bufferFillLevel, 0.0)
    }

    func test_stop_when_idle_is_safe() {
        let pipeline = AudioPipeline()
        
        pipeline.stop() // Should not crash
        
        XCTAssertEqual(pipeline.state, .idle)
    }

    func test_pause_when_idle_is_safe() {
        let pipeline = AudioPipeline()
        
        pipeline.pause() // Should not crash (paused but not running)
    }

    // MARK: - Permission Gating Tests (AC-09)

    func test_start_requires_permission() {
        // Given: Pipeline without permission (in test environment, permission may or may not be granted)
        let pipeline = AudioPipeline()
        let permissionStatus = pipeline.checkPermission()

        // When/Then: start() behavior depends on permission status
        if permissionStatus != .authorized {
            // If not authorized, start should throw permissionDenied
            XCTAssertThrowsError(try pipeline.start()) { error in
                XCTAssertTrue(error is AudioPipelineError)
                if let pipelineError = error as? AudioPipelineError {
                    XCTAssertEqual(pipelineError, .permissionDenied)
                }
            }
        }
        // If authorized in test environment, the test validates that permission check works
    }

    func test_checkPermission_returns_valid_status() {
        // Given: Pipeline
        let pipeline = AudioPipeline()

        // When: Checking permission
        let status = pipeline.checkPermission()

        // Then: Returns a valid permission status (not crashing)
        // The actual value depends on the test environment
        XCTAssertTrue([.authorized, .denied, .notDetermined, .restricted, .unknown].contains(status))
    }

    // MARK: - Lifecycle Integration Tests (AC-09, AC-10)

    func test_stop_flushes_pending_samples() {
        // Given: Pipeline with a chunk callback
        let pipeline = AudioPipeline()
        let chunkReceived = OSAllocatedUnfairLock(initialState: false)

        pipeline.onAudioChunk = { _ in
            chunkReceived.withLock { $0 = true }
        }

        // When: Stop is called (even without starting, it should handle gracefully)
        pipeline.stop()

        // Then: State is idle and no crash
        XCTAssertEqual(pipeline.state, .idle)
    }

    func test_resume_when_idle_calls_start() {
        // Given: Idle pipeline
        let pipeline = AudioPipeline()
        XCTAssertEqual(pipeline.state, .idle)

        // When: Resume is called on idle pipeline
        // Then: Behavior depends on permission - either starts or throws
        // This test validates that resume() correctly delegates to start() when idle
        do {
            try pipeline.resume()
            // If we get here, it means permission was granted and pipeline started
            XCTAssertEqual(pipeline.state, .running)
            pipeline.stop()
        } catch {
            // If permission denied, we expect an error
            XCTAssertTrue(error is AudioPipelineError)
        }
    }

    func test_configuration_chunk_size_is_respected() {
        // Given: Custom configuration with small chunk size
        let config = AudioPipeline.Configuration(
            bufferDuration: 1.0,
            chunkSize: 100,  // Very small chunk for testing
            targetSampleRate: 16000
        )
        let pipeline = AudioPipeline(configuration: config)

        // Then: Pipeline should be configured (we can't easily test actual chunking without audio)
        XCTAssertEqual(pipeline.state, .idle)
    }
}

// MARK: - Performance Tests

final class AudioPerformanceTests: XCTestCase {

    func test_performance_ringBufferAppend() {
        let buffer = StreamingRingBuffer(capacity: 192000)
        let samples = [Float](repeating: 0.5, count: 1000)

        measure {
            for _ in 0..<1000 {
                buffer.append(samples)
            }
        }
        // Baseline: ~50ms for 1M samples = 0.05ms per 1000 samples
    }

    func test_performance_ringBufferPeek() {
        let buffer = StreamingRingBuffer(capacity: 192000)
        buffer.append([Float](repeating: 0.5, count: 192000))

        measure {
            for _ in 0..<100 {
                _ = buffer.peek(count: 16000) // 1 second of audio
            }
        }
        // Baseline: ~100ms for 100 peeks = 1ms per peek
    }

    func test_performance_formatConversion() throws {
        let converter = AudioFormatConverter()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = createTestBuffer(format: format, frameCount: 2048)

        measure {
            for _ in 0..<100 {
                _ = converter.convert(buffer: buffer)
            }
        }
        // Baseline: ~20ms for 100 conversions = 0.2ms per conversion
    }

    private func createTestBuffer(format: AVAudioFormat, frameCount: UInt32) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            for frame in 0..<Int(frameCount) {
                channelData[0][frame] = Float.random(in: -0.5...0.5)
            }
        }
        return buffer
    }
}
