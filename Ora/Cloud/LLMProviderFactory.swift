//
//  LLMProviderFactory.swift
//  Ora
//
//  Factory protocol for creating cloud LLM provider instances
//

import Foundation

/// Factory for creating cloud LLM provider instances
public protocol LLMProviderFactory: Sendable {
    func create(apiKey: String) throws -> LLMServicing
}
