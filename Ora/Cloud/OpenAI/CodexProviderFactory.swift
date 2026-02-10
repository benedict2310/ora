//
//  CodexProviderFactory.swift
//  Ora
//
//  Factory for creating Codex OAuth-backed providers.
//

import Foundation

struct CodexProviderFactory: Sendable {
    let model: String
    private let credentialProvider: @Sendable () async throws -> CodexOAuthCredential

    init(
        model: String = OpenAIModel.gpt4o.rawValue,
        credentialProvider: @escaping @Sendable () async throws -> CodexOAuthCredential
    ) {
        self.model = model
        self.credentialProvider = credentialProvider
    }

    func create() -> CodexProvider {
        return CodexProvider(model: self.model, credentialProvider: self.credentialProvider)
    }
}
