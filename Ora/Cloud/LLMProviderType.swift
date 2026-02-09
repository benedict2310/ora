//
//  LLMProviderType.swift
//  Ora
//
//  Defines available LLM providers (Local vs Cloud)
//

import Foundation

/// Available LLM provider types
public enum LLMProviderType: String, Codable, Sendable, CaseIterable {
    case local       // MLX on-device (default)
    case anthropic   // Anthropic Claude API
    case openai      // OpenAI API key or Codex OAuth

    public var displayName: String {
        switch self {
        case .local: return "Local (On-Device)"
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI"
        }
    }

    /// Whether this provider requires network access
    public var isCloud: Bool {
        return self != .local
    }

    /// Corresponding CloudProvider for credential lookup (nil for local)
    var cloudProvider: CloudProvider? {
        switch self {
        case .local: return nil
        case .anthropic: return .anthropic
        case .openai: return .openai
        }
    }
}
