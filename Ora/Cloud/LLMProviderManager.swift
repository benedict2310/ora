//
//  LLMProviderManager.swift
//  Ora
//
//  Manages active LLM provider selection and lifecycle
//

import Foundation
import os

enum ProviderPreflightStatus: Sendable, Equatable {
    case ready
    case guidance(message: String)
}

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

        let preflight = await self.preflightForConversationStart()
        if case .guidance(let message) = preflight {
            self.logger.notice("Provider restore used fallback: \(message)")
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
        guard self.selectedProviderType == .local else {
            self.logger.notice("PROVIDER_CLEAR_CACHE_SKIPPED_FOR_CLOUD")
            return
        }
        await activeProvider.clearCache()
    }

    // MARK: - Provider Management

    /// Get the currently active LLM provider
    func currentProvider() -> LLMServicing {
        return activeProvider
    }
    
    /// Get the currently selected provider type
    func getSelectedProviderType() -> LLMProviderType {
        return self.selectedProviderType
    }

    /// Get selected model identifier for a provider
    func getSelectedModelIdentifier(for provider: LLMProviderType) -> String {
        switch provider {
        case .local:
            return ModelIdentifier.qwen3_4B.rawValue
        case .anthropic:
            return UserDefaults.standard.selectedAnthropicModel.rawValue
        case .openai:
            return UserDefaults.standard.selectedOpenAIModelIdentifier
        }
    }

    /// Get selected model display name for a provider
    func getSelectedModelDisplayName(for provider: LLMProviderType) -> String {
        switch provider {
        case .local:
            return ModelIdentifier.qwen3_4B.displayName
        case .anthropic:
            return UserDefaults.standard.selectedAnthropicModel.displayName
        case .openai:
            let identifier = UserDefaults.standard.selectedOpenAIModelIdentifier
            return OpenAIModel.displayName(for: identifier)
        }
    }

    /// Update selected model and reconnect active provider if needed
    func updateModelSelection(
        for provider: LLMProviderType,
        modelIdentifier: String
    ) async throws {
        switch provider {
        case .local:
            return
        case .anthropic:
            guard let model = AnthropicModel(rawValue: modelIdentifier) else {
                throw ProviderError.invalidModel(provider, modelIdentifier)
            }
            UserDefaults.standard.selectedAnthropicModel = model
            self.factories[.anthropic] = AnthropicProviderFactory(model: model.rawValue)
        case .openai:
            let trimmed = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ProviderError.invalidModel(provider, modelIdentifier)
            }
            UserDefaults.standard.selectedOpenAIModelIdentifier = trimmed
            self.factories[.openai] = OpenAIProviderFactory(model: trimmed)
        }

        guard self.selectedProviderType == provider else { return }
        try await self.switchProvider(to: provider)
    }

    /// Validate provider/model readiness before generation begins.
    func preflightForConversationStart() async -> ProviderPreflightStatus {
        let selectedType = self.selectedProviderType
        guard selectedType.isCloud else {
            return .ready
        }

        if selectedType == .openai {
            self.reconcileOpenAIModelSelectionIfNeeded()
        }

        do {
            try await self.ensureCredentialExists(for: selectedType)
        } catch {
            return await self.fallbackToLocal(
                reason: "Missing credential for \(selectedType.rawValue): \(error.localizedDescription)",
                guidance: "\(selectedType.displayName) is not configured. I switched to Local (Qwen 3 4B). Open Preferences > Providers to reconnect."
            )
        }

        do {
            if self.isActiveProviderAligned(with: selectedType) {
                try await self.activeProvider.prepare()
            } else {
                try await self.switchProvider(to: selectedType)
            }
            return .ready
        } catch {
            return await self.fallbackToLocal(
                reason: "Provider preflight failed for \(selectedType.rawValue): \(error.localizedDescription)",
                guidance: "I could not connect to \(selectedType.displayName), so I switched to Local (Qwen 3 4B). Open Preferences > Providers to fix the connection."
            )
        }
    }

    /// Switch to a different provider
    func switchProvider(to type: LLMProviderType) async throws {
        // Skip if already on the requested type (unless we want to force reload)
        // Note: We don't skip if we are initializing (activeProvider might be local default)
        if type == self.selectedProviderType && type == .local && self.activeProvider is LLMService {
            return
        }

        // Unload current if it's local (cloud providers don't need unload)
        if self.selectedProviderType == .local {
            await self.activeProvider.unload()
        }

        // Resolve new provider
        let provider = try await self.resolveProvider(type)

        // Update state
        self.activeProvider = provider
        self.selectedProviderType = type
        UserDefaults.standard.selectedLLMProvider = type

        // Prepare the new provider
        try await provider.prepare()

        self.logger.info("Switched to provider: \(type.rawValue)")
        
        // Post notification
        await MainActor.run {
             NotificationCenter.default.post(name: .llmProviderChanged, object: nil, userInfo: ["type": type])
        }
    }

    /// Register a provider factory
    func register(factory: LLMProviderFactory, for type: LLMProviderType) {
        self.factories[type] = factory
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
                    model: UserDefaults.standard.selectedOpenAIModelIdentifier
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
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.noCredential(type)
        }

        return try factory.create(apiKey: apiKey)
    }

    private func ensureCredentialExists(for type: LLMProviderType) async throws {
        if type == .openai {
            if let _ = try await self.codexOAuthManager.validCredentialIfAvailable() {
                return
            }
        }
        guard let cloudProvider = type.cloudProvider else { return }
        let apiKey = try await self.credentialStore.retrieve(provider: cloudProvider)
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.noCredential(type)
        }
    }

    private func isActiveProviderAligned(with type: LLMProviderType) -> Bool {
        switch type {
        case .local:
            return self.activeProvider is LLMService
        case .anthropic:
            return self.activeProvider is AnthropicProvider
        case .openai:
            return self.activeProvider is OpenAIProvider || self.activeProvider is CodexProvider
        }
    }

    private func fallbackToLocal(
        reason: String,
        guidance: String
    ) async -> ProviderPreflightStatus {
        self.logger.error("Provider fallback to local: \(reason)")
        self.selectedProviderType = .local
        self.activeProvider = LLMService.shared
        UserDefaults.standard.selectedLLMProvider = .local

        await MainActor.run {
            NotificationCenter.default.post(
                name: .llmProviderChanged,
                object: nil,
                userInfo: ["type": LLMProviderType.local]
            )
        }

        return .guidance(message: guidance)
    }

    private func reconcileOpenAIModelSelectionIfNeeded() {
        let discoveredModelIDs = UserDefaults.standard.openAIDiscoveredModelIdentifiers
        guard !discoveredModelIDs.isEmpty else { return }

        let selectedModelID = UserDefaults.standard.selectedOpenAIModelIdentifier
        guard !discoveredModelIDs.contains(selectedModelID) else { return }

        let fallbackModelID: String
        if discoveredModelIDs.contains(OpenAIModel.preferredDefault.rawValue) {
            fallbackModelID = OpenAIModel.preferredDefault.rawValue
        } else {
            fallbackModelID = discoveredModelIDs[0]
        }

        self.logger.warning(
            "Selected OpenAI model unavailable: \(selectedModelID). Falling back to \(fallbackModelID)"
        )
        UserDefaults.standard.selectedOpenAIModelIdentifier = fallbackModelID

        if let existingFactory = self.factories[.openai], !(existingFactory is OpenAIProviderFactory) {
            return
        }
        self.factories[.openai] = OpenAIProviderFactory(model: fallbackModelID)
    }
}

// MARK: - Extensions

extension Notification.Name {
    static let llmProviderChanged = Notification.Name("LLMProviderChanged")
}

extension UserDefaults {
    private enum Key {
        static let selectedLLMProvider = "com.ora.selectedLLMProvider"
        static let selectedAnthropicModel = "com.ora.selectedAnthropicModel"
        static let selectedOpenAIModel = "com.ora.selectedOpenAIModel"
        static let selectedOpenAIModelIdentifier = "com.ora.selectedOpenAIModelIdentifier"
        static let openAIDiscoveredModelIdentifiers = "com.ora.openAI.discoveredModelIdentifiers"
    }

    var selectedLLMProvider: LLMProviderType {
        get {
            guard let raw = string(forKey: Key.selectedLLMProvider),
                  let type = LLMProviderType(rawValue: raw) else {
                return .local
            }
            return type
        }
        set {
            set(newValue.rawValue, forKey: Key.selectedLLMProvider)
        }
    }

    var selectedAnthropicModel: AnthropicModel {
        get {
            guard let raw = string(forKey: Key.selectedAnthropicModel),
                  let model = AnthropicModel(rawValue: raw) else {
                return .sonnet
            }
            return model
        }
        set {
            set(newValue.rawValue, forKey: Key.selectedAnthropicModel)
        }
    }

    var selectedOpenAIModelIdentifier: String {
        get {
            if let raw = string(forKey: Key.selectedOpenAIModelIdentifier),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return raw
            }
            if let legacyRaw = string(forKey: Key.selectedOpenAIModel),
               !legacyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return legacyRaw
            }
            return OpenAIModel.preferredDefault.rawValue
        }
        set {
            set(newValue, forKey: Key.selectedOpenAIModelIdentifier)
            set(newValue, forKey: Key.selectedOpenAIModel)
        }
    }

    var selectedOpenAIModel: OpenAIModel {
        get {
            guard let raw = OpenAIModel(rawValue: self.selectedOpenAIModelIdentifier) else {
                return .preferredDefault
            }
            return raw
        }
        set {
            self.selectedOpenAIModelIdentifier = newValue.rawValue
        }
    }

    var openAIDiscoveredModelIdentifiers: [String] {
        get {
            guard let raw = array(forKey: Key.openAIDiscoveredModelIdentifiers) as? [String] else {
                return []
            }
            return raw.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        set {
            var seen: Set<String> = []
            let deduped = newValue.filter { identifier in
                let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                guard !seen.contains(trimmed) else { return false }
                seen.insert(trimmed)
                return true
            }
            set(deduped, forKey: Key.openAIDiscoveredModelIdentifiers)
        }
    }
}
