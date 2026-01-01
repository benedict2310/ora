//
//  PipelineState.swift
//  Ora
//
//  State definitions for the simple ASR-LLM pipeline
//

import Foundation

/// Current state of the pipeline
enum PipelineState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case responding
    case completed
    case error(String)
    
    /// Human-readable description
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .responding: return "Responding..."
        case .completed: return "Done"
        case .error(let msg): return "Error: \(msg)"
        }
    }
    
    /// Whether this state allows starting a new listening session
    var canStartListening: Bool {
        switch self {
        case .idle, .completed, .error:
            return true
        case .listening, .thinking, .responding:
            return false
        }
    }
}
