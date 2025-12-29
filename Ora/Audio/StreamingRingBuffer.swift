//
//  StreamingRingBuffer.swift
//  Ora
//
//  Thread-safe circular buffer for streaming audio samples.
//

import Foundation
import os

/// Thread-safe circular buffer for streaming audio samples.
///
/// ## Design Goals
/// - Fixed-size buffer (10-12 seconds of audio context)
/// - Thread-safe for concurrent read/write
/// - Minimal lock contention using OSAllocatedUnfairLock
/// - Priority inheritance for audio thread safety
///
/// ## Usage Pattern
/// ```swift
/// let buffer = StreamingRingBuffer(capacity: 192000) // 12 seconds @ 16kHz
///
/// // Producer (audio callback thread)
/// buffer.append(samples)
///
/// // Consumer (transcription thread)
/// let context = buffer.read(count: 16000) // 1 second
/// ```
///
/// ## Memory Layout
/// ```
/// [......|xxxxxxxx|......]
///        ^tail    ^head
/// ```
/// - `tail`: Index of oldest sample (read position)
/// - `head`: Index for next write
/// - When buffer is full, oldest samples are overwritten
final class StreamingRingBuffer: @unchecked Sendable {

    // MARK: - Types

    private struct State {
        var buffer: [Float]
        var head: Int = 0
        var tail: Int = 0
        var count: Int = 0
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer = [Float](repeating: 0, count: capacity)
        }
    }

    // MARK: - Properties

    private let state: OSAllocatedUnfairLock<State>

    /// Maximum number of samples this buffer can hold
    let capacity: Int

    // MARK: - Initialization

    /// Create a ring buffer with the specified capacity
    /// - Parameter capacity: Maximum number of Float samples to store
    init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        self.state = OSAllocatedUnfairLock(initialState: State(capacity: capacity))
    }

    /// Create a ring buffer with capacity for specified duration
    /// - Parameters:
    ///   - duration: Duration in seconds
    ///   - sampleRate: Sample rate (default 16000 for Parakeet)
    convenience init(duration: TimeInterval, sampleRate: Int = 16000) {
        let capacity = Int(ceil(duration * Double(sampleRate)))
        self.init(capacity: capacity)
    }

    // MARK: - Properties (Thread-Safe)

    /// Number of samples currently in the buffer
    var count: Int {
        state.withLock { $0.count }
    }

    /// Available space for new samples
    var availableSpace: Int {
        state.withLock { $0.capacity - $0.count }
    }

    /// Whether the buffer is empty
    var isEmpty: Bool {
        state.withLock { $0.count == 0 }
    }

    /// Whether the buffer is full
    var isFull: Bool {
        state.withLock { $0.count == $0.capacity }
    }

    /// Current fill level as percentage (0.0 - 1.0)
    var fillLevel: Double {
        state.withLock { Double($0.count) / Double($0.capacity) }
    }

    // MARK: - Write Operations

    /// Append samples to the buffer
    ///
    /// If the buffer is full, oldest samples are overwritten.
    /// This ensures the buffer always contains the most recent audio.
    ///
    /// - Parameter samples: Array of Float samples to append
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        state.withLock { state in
            for sample in samples {
                state.buffer[state.head] = sample
                state.head = (state.head + 1) % state.capacity

                if state.count == state.capacity {
                    // Buffer full - advance tail (discard oldest)
                    state.tail = (state.tail + 1) % state.capacity
                } else {
                    state.count += 1
                }
            }
        }
    }

    /// Append samples from an unsafe buffer pointer (zero-copy from audio buffer)
    /// - Parameter bufferPointer: Pointer to Float samples
    /// - Note: This method copies the samples synchronously before returning
    func append(from bufferPointer: UnsafeBufferPointer<Float>) {
        guard !bufferPointer.isEmpty else { return }

        // Copy samples to array first to avoid Sendable issues
        let samples = Array(bufferPointer)
        append(samples)
    }

    // MARK: - Read Operations

    /// Read samples from the buffer without removing them
    ///
    /// Returns up to `count` samples starting from the oldest.
    /// Useful for getting audio context for transcription.
    ///
    /// - Parameter count: Maximum number of samples to read
    /// - Returns: Array of samples (may be fewer than requested if buffer is partially filled)
    func peek(count: Int) -> [Float] {
        state.withLock { state in
            let readCount = min(count, state.count)
            guard readCount > 0 else { return [] }

            var result = [Float]()
            result.reserveCapacity(readCount)

            var readIndex = state.tail
            for _ in 0..<readCount {
                result.append(state.buffer[readIndex])
                readIndex = (readIndex + 1) % state.capacity
            }

            return result
        }
    }

    /// Read and remove samples from the buffer
    ///
    /// - Parameter count: Maximum number of samples to read and remove
    /// - Returns: Array of samples removed from buffer
    func read(count: Int) -> [Float] {
        state.withLock { state in
            let readCount = min(count, state.count)
            guard readCount > 0 else { return [] }

            var result = [Float]()
            result.reserveCapacity(readCount)

            for _ in 0..<readCount {
                result.append(state.buffer[state.tail])
                state.tail = (state.tail + 1) % state.capacity
                state.count -= 1
            }

            return result
        }
    }

    /// Read all available samples without removing them
    /// - Returns: Array of all samples currently in buffer
    func peekAll() -> [Float] {
        peek(count: capacity)
    }

    /// Read all samples and clear the buffer
    /// - Returns: Array of all samples that were in buffer
    func drain() -> [Float] {
        state.withLock { state in
            guard state.count > 0 else { return [] }

            var result = [Float]()
            result.reserveCapacity(state.count)

            while state.count > 0 {
                result.append(state.buffer[state.tail])
                state.tail = (state.tail + 1) % state.capacity
                state.count -= 1
            }

            return result
        }
    }

    // MARK: - Buffer Management

    /// Reset the buffer to empty state
    ///
    /// Clears all samples and resets head/tail pointers.
    /// Does not deallocate memory.
    func reset() {
        state.withLock { state in
            state.head = 0
            state.tail = 0
            state.count = 0
        }
    }

    /// Skip (remove) samples without reading
    /// - Parameter count: Number of samples to skip
    func skip(_ count: Int) {
        state.withLock { state in
            let skipCount = min(count, state.count)
            state.tail = (state.tail + skipCount) % state.capacity
            state.count -= skipCount
        }
    }
}

// MARK: - Convenience Extensions

extension StreamingRingBuffer {
    /// Duration of audio currently in buffer (at 16kHz)
    var duration: TimeInterval {
        TimeInterval(count) / 16000.0
    }

    /// Read samples for a specific duration
    /// - Parameter seconds: Duration in seconds
    /// - Returns: Samples covering that duration
    func peek(seconds: TimeInterval) -> [Float] {
        let sampleCount = Int(seconds * 16000)
        return peek(count: sampleCount)
    }
}
