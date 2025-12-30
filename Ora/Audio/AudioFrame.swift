//
//  AudioFrame.swift
//  Ora
//
//  Audio frame for ASR processing.
//

import Foundation

/// A chunk of audio samples for ASR processing.
///
/// ## Format
/// - Sample rate: 16kHz (Parakeet requirement)
/// - Channels: Mono
/// - Format: Float32
///
/// ## Usage
/// ```swift
/// let frame = AudioFrame(samples: samples, timestamp: 0)
/// print("Duration: \(frame.duration)s")
/// ```
struct AudioFrame: Sendable {

    // MARK: - Properties

    /// PCM samples (16kHz mono Float32)
    let samples: [Float]

    /// Sample rate (always 16000 for Parakeet)
    let sampleRate: Int

    /// Timestamp (samples since stream start)
    let timestamp: UInt64

    // MARK: - Computed Properties

    /// Duration in seconds
    var duration: TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }

    /// Number of samples in this frame
    var count: Int {
        samples.count
    }

    /// Whether the frame is empty
    var isEmpty: Bool {
        samples.isEmpty
    }

    // MARK: - Initialization

    /// Create an audio frame with the given samples
    /// - Parameters:
    ///   - samples: PCM samples (16kHz mono Float32)
    ///   - sampleRate: Sample rate (default 16000 for Parakeet)
    ///   - timestamp: Timestamp in samples since stream start
    init(samples: [Float], sampleRate: Int = 16000, timestamp: UInt64 = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }
}
