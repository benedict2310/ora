//
//  ASREngine.swift
//  Ora
//
//  Protocol and data types for ASR engine abstraction
//

import Foundation
@preconcurrency import AVFoundation

// MARK: - Data Structures

/// Represents a single recognized word with optional timing and confidence
struct ASRWord: Sendable, Equatable {
    let text: String
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let confidence: Float?
}

/// Partial/streaming transcription result
struct ASRPartial: Sendable, Equatable {
    let text: String
    let words: [ASRWord]
}

/// Final, committed transcription segment
struct ASRFinalSegment: Sendable, Equatable {
    let text: String
    let words: [ASRWord]
}

// MARK: - Protocol

/// Core ASR engine protocol for transcription operations
protocol ASREngine: Sendable {
    /// Prepare the engine (load models, initialize state)
    func prepare() async throws

    /// Reset decoder state for a new transcription session
    func reset() async

    /// Process audio buffer, returning partial results
    /// - Parameters:
    ///   - buffer: 16kHz mono Float32 PCM audio
    ///   - language: Optional language hint (e.g., "en", "de")
    /// - Returns: Partial transcription result, or nil if insufficient audio
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial?

    /// Finalize transcription and return committed result
    /// - Parameters:
    ///   - buffer: Remaining audio buffer
    ///   - language: Optional language hint
    /// - Returns: Final transcription segment
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment?

    /// Set handler for streaming partial results
    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?)
}

// MARK: - Convenience Extensions

extension ASREngine {
    /// Process audio from Float32 sample array
    func process(samples: [Float], language: String? = nil) async throws -> ASRPartial? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await process(buffer, language: language)
    }

    /// Finalize from Float32 sample array
    func finalize(samples: [Float], language: String? = nil) async throws -> ASRFinalSegment? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await finalize(buffer, language: language)
    }

    /// Create AVAudioPCMBuffer from Float32 samples (16kHz mono)
    static func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress,
                  let channelData = buffer.floatChannelData else { return }
            memcpy(channelData[0], baseAddress, samples.count * MemoryLayout<Float>.stride)
        }

        return buffer
    }
}
