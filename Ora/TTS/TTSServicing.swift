//
//  TTSServicing.swift
//  Ora
//
//  Protocol for TTS service abstraction
//

import Foundation

/// Protocol for text-to-speech services
public protocol TTSServicing: Sendable {
    /// Generate speech audio from text
    /// - Parameter text: Text to synthesize
    /// - Returns: Async stream of audio chunks
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>
    
    /// Stop current speech synthesis
    func stop() async
}

/// Errors that can occur during TTS operations
public enum TTSError: LocalizedError {
    case modelNotFound
    case initializationFailed(String)
    case synthesisFailed(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "TTS model not found. Please download the Kokoro model."
        case .initializationFailed(let reason):
            return "TTS initialization failed: \(reason)"
        case .synthesisFailed(let reason):
            return "Speech synthesis failed: \(reason)"
        case .cancelled:
            return "Speech synthesis was cancelled."
        }
    }
}
