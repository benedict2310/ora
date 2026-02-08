//
//  AnthropicModels.swift
//  Ora
//
//  Anthropic Claude model configuration
//

import Foundation

/// Available Anthropic Claude models
public enum AnthropicModel: String, Sendable, CaseIterable {
    case sonnet = "claude-sonnet-4-20250514"
    case haiku = "claude-haiku-4-20250514"
    case opus = "claude-opus-4-20250514"

    public var displayName: String {
        switch self {
        case .sonnet: return "Claude Sonnet 4"
        case .haiku: return "Claude Haiku 4"
        case .opus: return "Claude Opus 4"
        }
    }

    public var maxOutputTokens: Int {
        switch self {
        case .sonnet: return 8192
        case .haiku: return 8192
        case .opus: return 8192
        }
    }
}
