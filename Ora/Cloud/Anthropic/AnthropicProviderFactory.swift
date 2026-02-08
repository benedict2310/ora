//
//  AnthropicProviderFactory.swift
//  Ora
//
//  Factory for creating Anthropic provider instances
//

import Foundation

/// Factory for creating Anthropic Claude provider instances
public struct AnthropicProviderFactory: LLMProviderFactory {
    public let model: String

    public init(model: String = AnthropicModel.sonnet.rawValue) {
        self.model = model
    }

    public func create(apiKey: String) throws -> LLMServicing {
        return AnthropicProvider(apiKey: apiKey, model: model)
    }
}
