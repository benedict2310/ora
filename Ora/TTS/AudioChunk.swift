//
//  AudioChunk.swift
//  Ora
//
//  Audio data structure for streaming TTS output
//

import Foundation

/// Audio chunk for TTS playback
public struct AudioChunk: Sendable, Equatable {
    /// PCM audio samples in Float32 format
    public let samples: [Float]
    
    /// Sample rate in Hz (typically 24000 for Kokoro)
    public let sampleRate: Int
    
    /// Duration of this chunk in seconds
    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
    
    /// Whether this is an empty marker chunk (e.g., signaling fallback playback started)
    public var isEmpty: Bool {
        samples.isEmpty
    }
    
    /// Create an audio chunk
    /// - Parameters:
    ///   - samples: PCM Float32 audio samples
    ///   - sampleRate: Sample rate in Hz
    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
    
    /// Create an empty marker chunk
    /// - Parameter sampleRate: Sample rate in Hz
    public static func empty(sampleRate: Int = 24000) -> AudioChunk {
        AudioChunk(samples: [], sampleRate: sampleRate)
    }
}
