//
//  StreamingASRConfiguration.swift
//  Ora
//
//  Configuration for streaming ASR behavior
//

import Foundation
import FluidAudio

// MARK: - Streaming ASR Configuration

/// Configuration for streaming ASR behavior
struct StreamingASRConfiguration: Sendable, Equatable {

    /// Chunk size for streaming processing
    enum ChunkSize: String, Sendable, CaseIterable {
        /// 160ms chunks - lowest latency, ~8-9% WER
        case ms160

        /// 320ms chunks - higher accuracy, ~5.7% WER
        case ms320

        var fluidAudioChunkSize: StreamingChunkSize {
            switch self {
            case .ms160: return .ms160
            case .ms320: return .ms320
            }
        }

        var displayName: String {
            switch self {
            case .ms160: return "160ms (Low Latency)"
            case .ms320: return "320ms (Higher Accuracy)"
            }
        }
    }

    /// Chunk size for streaming (default: 160ms for lowest latency)
    var chunkSize: ChunkSize = .ms160

    /// EOU debounce duration in milliseconds.
    /// Minimum silence duration before End-of-Utterance is confirmed.
    /// Lower values = more responsive but may cut off during pauses.
    /// Recommended: 600ms for voice commands, 800ms for natural speech.
    var eouDebounceMs: Int = 600

    /// Default configuration optimized for voice assistant use
    static let `default` = StreamingASRConfiguration()

    /// Responsive configuration for quick commands
    static let responsive = StreamingASRConfiguration(
        chunkSize: .ms160,
        eouDebounceMs: 400
    )

    /// Balanced configuration for natural conversation
    static let balanced = StreamingASRConfiguration(
        chunkSize: .ms160,
        eouDebounceMs: 800
    )

    /// Conservative configuration for complete sentences
    static let conservative = StreamingASRConfiguration(
        chunkSize: .ms320,
        eouDebounceMs: 1000
    )
}
