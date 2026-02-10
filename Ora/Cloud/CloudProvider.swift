//
//  CloudProvider.swift
//  Ora
//
//  Cloud LLM provider types
//

import Foundation

/// Identifies a cloud LLM provider
enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case openaiCodex

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openaiCodex: return "OpenAI Codex OAuth"
        }
    }

    /// Expected key prefix for basic validation (not a security check)
    var keyPrefix: String? {
        switch self {
        case .anthropic: return "sk-ant-"
        case .openai: return "sk-"
        case .openaiCodex: return nil
        }
    }
}
