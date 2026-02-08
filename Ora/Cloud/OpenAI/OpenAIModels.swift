//
//  OpenAIModels.swift
//  Ora
//
//  OpenAI model configuration
//

import Foundation

/// Available OpenAI models
public enum OpenAIModel: String, Sendable, CaseIterable {
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case o3Mini = "o3-mini"

    public var displayName: String {
        switch self {
        case .gpt4o: return "GPT-4o"
        case .gpt4oMini: return "GPT-4o Mini"
        case .o3Mini: return "o3-mini"
        }
    }
}
