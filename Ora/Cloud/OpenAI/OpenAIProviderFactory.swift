//
//  OpenAIProviderFactory.swift
//  Ora
//
//  Factory for creating OpenAI provider instances
//

import Foundation

/// Factory for creating OpenAI provider instances
public struct OpenAIProviderFactory: LLMProviderFactory {
    public let model: String

    public init(model: String = OpenAIModel.gpt4o.rawValue) {
        self.model = model
    }

    public func create(apiKey: String) throws -> LLMServicing {
        return OpenAIProvider(apiKey: apiKey, model: model)
    }
}
