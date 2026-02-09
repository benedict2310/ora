//
//  LLMProviderManager.swift
//  Ora
//
//  Manages active LLM provider selection and lifecycle
//

import Foundation
import os

/// Manages active LLM provider selection and lifecycle
/// Conforms to LLMServicing to allow transparent injection into AgentLoop
actor LLMProviderManager: LLMServicing {

    static let shared = LLMProviderManager()

    private let logger = Logger(subsystem: "com.ora.app", category: "providers")
    private let credentialStore: CredentialStore
    private let codexOAuthManager: CodexOAuthManaging

    /// Currently active provider
    private var activeProvider: LLMServicing

    /// Provider configuration
    private var selectedProviderType: LLMProviderType

    /// Available provider factories
    private var factories: [LLMProviderType: LLMProviderFactory] = [:]

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        codexOAuthManager: CodexOAuthManaging = CodexOAuthManager.shared
    ) {
        self.credentialStore = credentialStore
        self.codexOAuthManager = codexOAuthManager
        
        // Load preference
        let savedType = UserDefaults.standard.selectedLLMProvider
        self.selectedProviderType = savedType
        
        // Default to local initially
        self.activeProvider = LLMService.shared
    }

    func restoreSelectedProviderIfNeeded() async {
        guard self.selectedProviderType != .local else {
            return
        }

        do {
            try await self.switchProvider(to: self.selectedProviderType)
        } catch {
            self.logger.error("Failed to restore provider \(self.selectedProviderType.rawValue): \(error.localizedDescription)")
            // Fallback to local
            self.selectedProviderType = .local
            UserDefaults.standard.selectedLLMProvider = .local
        }
    }

    // MARK: - LLMServicing Proxy

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return await activeProvider.generate(messages: messages, maxTokens: maxTokens)
    }

    func warmup() async throws {
        try await activeProvider.warmup()
    }

    func prepare() async throws {
        try await activeProvider.prepare()
    }

    func unload() async {
        await activeProvider.unload()
    }

    func clearCache() async {
        await activeProvider.clearCache()
    }

    // MARK: - Provider Management

    /// Get the currently active LLM provider
    func currentProvider() -> LLMServicing {
        return activeProvider
    }
    
    /// Get the currently selected provider type
    func getSelectedProviderType() -> LLMProviderType {
        return selectedProviderType
    }

    /// Switch to a different provider
    func switchProvider(to type: LLMProviderType) async throws {
        // Skip if already on the requested type (unless we want to force reload)
        // Note: We don't skip if we are initializing (activeProvider might be local default)
        if type == selectedProviderType && type == .local && activeProvider is LLMService {
            return
        }

        // Unload current if it's local (cloud providers don't need unload)
        if selectedProviderType == .local {
            await activeProvider.unload()
        }

        // Resolve new provider
        let provider = try await resolveProvider(type)

        // Update state
        activeProvider = provider
        selectedProviderType = type
        UserDefaults.standard.selectedLLMProvider = type

        // Prepare the new provider
        try await provider.prepare()

        logger.info("Switched to provider: \(type.rawValue)")
        
        // Post notification
        await MainActor.run {
             NotificationCenter.default.post(name: .llmProviderChanged, object: nil, userInfo: ["type": type])
        }
    }

    /// Register a provider factory
    func register(factory: LLMProviderFactory, for type: LLMProviderType) {
        factories[type] = factory
    }

    private func resolveProvider(_ type: LLMProviderType) async throws -> LLMServicing {
        switch type {
        case .local:
            return LLMService.shared
        case .anthropic:
            return try await self.resolveAPIKeyProvider(for: .anthropic)
        case .openai:
            if let _ = try await self.codexOAuthManager.validCredentialIfAvailable() {
                self.logger.info("Using Codex OAuth credential for OpenAI provider")
                let factory = CodexProviderFactory(
                    model: UserDefaults.standard.selectedOpenAIModel.rawValue
                ) { [codexOAuthManager = self.codexOAuthManager] in
                    guard let credential = try await codexOAuthManager.validCredentialIfAvailable() else {
                        throw ProviderError.noCredential(.openai)
                    }
                    return credential
                }
                return factory.create()
            }

            return try await self.resolveAPIKeyProvider(for: .openai)
        }
    }

    private func resolveAPIKeyProvider(for type: LLMProviderType) async throws -> LLMServicing {
        guard let factory = self.factories[type] else {
            throw ProviderError.providerNotRegistered(type)
        }

        guard let cloudProvider = type.cloudProvider else {
            throw ProviderError.switchFailed(type, CloudProviderError.invalidResponse("Invalid provider type"))
        }

        guard let apiKey = try await self.credentialStore.retrieve(provider: cloudProvider),
              !apiKey.isEmpty else {
            throw ProviderError.noCredential(type)
        }

        return try factory.create(apiKey: apiKey)
    }
}

// MARK: - Extensions

extension Notification.Name {
    static let llmProviderChanged = Notification.Name("LLMProviderChanged")
}

extension UserDefaults {
    var selectedLLMProvider: LLMProviderType {
        get {
            guard let raw = string(forKey: "com.ora.selectedLLMProvider"),
                  let type = LLMProviderType(rawValue: raw) else {
                return .local
            }
            return type
        }
        set {
            set(newValue.rawValue, forKey: "com.ora.selectedLLMProvider")
        }
    }

    var selectedAnthropicModel: AnthropicModel {
        get {
            guard let raw = string(forKey: "com.ora.selectedAnthropicModel"),
                  let model = AnthropicModel(rawValue: raw) else {
                return .sonnet
            }
            return model
        }
        set {
            set(newValue.rawValue, forKey: "com.ora.selectedAnthropicModel")
        }
    }

    var selectedOpenAIModel: OpenAIModel {
        get {
            guard let raw = string(forKey: "com.ora.selectedOpenAIModel"),
                  let model = OpenAIModel(rawValue: raw) else {
                return .gpt4o
            }
            return model
        }
        set {
            set(newValue.rawValue, forKey: "com.ora.selectedOpenAIModel")
        }
    }
}
