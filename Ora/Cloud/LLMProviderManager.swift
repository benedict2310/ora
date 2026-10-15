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

    private let logger = Logger.ora(category: "providers")
    private let credentialStore: CredentialStore
    private let codexOAuthManager: CodexOAuthManaging
    private let localProvider: LLMService
    private let persistSelection: @Sendable (LLMProviderType) -> Void
    private let injectedProviderResolver: (@Sendable (LLMProviderType) async throws -> any LLMServicing)?
    private let beforeLocalPreparation: @Sendable () async -> Void

    /// Currently active provider
    private var activeProvider: LLMServicing

    /// Provider configuration
    private var selectedProviderType: LLMProviderType
    private var preparationEpoch: UInt64 = 0
    private var providerTransitions = 0

    /// Available provider factories
    private var factories: [LLMProviderType: LLMProviderFactory] = [:]

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        codexOAuthManager: CodexOAuthManaging = CodexOAuthManager.shared,
        localProvider: LLMService = .shared,
        selectedProviderType: LLMProviderType? = nil,
        persistSelection: @escaping @Sendable (LLMProviderType) -> Void = { UserDefaults.standard.selectedLLMProvider = $0 },
        providerResolver: (@Sendable (LLMProviderType) async throws -> any LLMServicing)? = nil,
        beforeLocalPreparation: @escaping @Sendable () async -> Void = {}
    ) {
        self.credentialStore = credentialStore
        self.codexOAuthManager = codexOAuthManager
        self.localProvider = localProvider
        self.persistSelection = persistSelection
        self.injectedProviderResolver = providerResolver
        self.beforeLocalPreparation = beforeLocalPreparation

        // Explicit selections let model-free tests avoid reading application preferences.
        let savedType = selectedProviderType ?? UserDefaults.standard.selectedLLMProvider
        self.selectedProviderType = savedType
        
        // Default to local initially
        self.activeProvider = localProvider
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
        let type = self.selectedProviderType
        let provider = self.activeProvider
        let epoch = self.preparationEpoch
        guard type != .local || self.providerTransitions == 0 else { throw LLMServiceError.preparationInvalidated }
        self.logger.notice("LLM_PREPARE_FOREGROUND_REQUESTED provider=\(type.rawValue, privacy: .public)")
        do {
            if type == .local, let local = provider as? LLMService {
                try await local.prepareIfEligible { [weak self] in
                    await self?.isLocalPreparationCurrent(epoch: epoch) ?? false
                }
            } else {
                try await provider.prepare()
            }
            guard type != .local || epoch == self.preparationEpoch else { throw LLMServiceError.preparationInvalidated }
            self.logger.notice("LLM_PREPARE_FOREGROUND_COMPLETED provider=\(type.rawValue, privacy: .public)")
        } catch {
            self.logger.notice("LLM_PREPARE_FOREGROUND_FAILED provider=\(type.rawValue, privacy: .public)")
            throw error
        }
    }

    /// Best-effort preparation used while voice capture is active. It is deliberately
    /// local-only: cloud credentials and provider preflight remain foreground-only.
    func prepareLocalIfEligible() async {
        guard self.providerTransitions == 0, self.selectedProviderType == .local,
              let provider = self.activeProvider as? LLMService else {
            self.logger.notice("LLM_PREPARE_EARLY_SKIPPED provider=\(self.selectedProviderType.rawValue, privacy: .public) reason=ineligible")
            return
        }
        let epoch = self.preparationEpoch
        self.logger.notice("LLM_PREPARE_EARLY_REQUESTED provider=local")
        // The scheduling seam lets tests delay the actual actor entry, not a fake policy.
        await self.beforeLocalPreparation()
        do {
            try await provider.prepareIfEligible { [weak self] in
                await self?.isLocalPreparationCurrent(epoch: epoch) ?? false
            }
            guard epoch == self.preparationEpoch else {
                self.logger.notice("LLM_PREPARE_EARLY_INVALIDATED provider=local")
                return
            }
            self.logger.notice("LLM_PREPARE_EARLY_COMPLETED provider=local")
        } catch {
            self.logger.notice("LLM_PREPARE_EARLY_FAILED provider=local")
        }
    }

    private func isLocalPreparationCurrent(epoch: UInt64) -> Bool {
        epoch == self.preparationEpoch && self.providerTransitions == 0 && self.selectedProviderType == .local
    }

    func unload() async {
        self.preparationEpoch &+= 1
        await activeProvider.unload()
    }

    func clearCache() async {
        guard self.selectedProviderType == .local else {
            self.logger.notice("PROVIDER_CLEAR_CACHE_SKIPPED_FOR_CLOUD")
            return
        }
        await activeProvider.clearCache()
    }

    func capabilities() async -> ProviderCapabilities {
        return await self.activeProvider.capabilities()
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
            return ModelIdentifier.recommendedLocalLLM().rawValue
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
            return ModelIdentifier.recommendedLocalLLM().displayName
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
            let localModelName = ModelIdentifier.recommendedLocalLLM().displayName
            return await self.fallbackToLocal(
                reason: "Missing credential for \(selectedType.rawValue): \(error.localizedDescription)",
                guidance: "\(selectedType.displayName) is not configured. I switched to Local (\(localModelName)). Open Preferences > Providers to reconnect."
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
            let localModelName = ModelIdentifier.recommendedLocalLLM().displayName
            return await self.fallbackToLocal(
                reason: "Provider preflight failed for \(selectedType.rawValue): \(error.localizedDescription)",
                guidance: "I could not connect to \(selectedType.displayName), so I switched to Local (\(localModelName)). Open Preferences > Providers to fix the connection."
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

        // Fence preparation only; retain the existing provider-switch ordering.
        self.preparationEpoch &+= 1
        self.providerTransitions += 1
        defer { self.providerTransitions -= 1 }

        // Unload current if it's local (cloud providers don't need unload)
        if self.selectedProviderType == .local {
            await self.activeProvider.unload()
        }

        // Resolve new provider
        let provider = try await self.resolveProvider(type)

        // Update state
        self.activeProvider = provider
        self.selectedProviderType = type
        self.persistSelection(type)

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
        if let injectedProviderResolver { return try await injectedProviderResolver(type) }
        switch type {
        case .local:
            return self.localProvider
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
        self.activeProvider = self.localProvider
        self.persistSelection(.local)

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
    var selectedLLMProvider: LLMProviderType {
        get {
            guard let raw = string(forKey: OraKey.selectedLLMProvider),
                  let type = LLMProviderType(rawValue: raw) else {
                return .local
            }
            return type
        }
        set {
            set(newValue.rawValue, forKey: OraKey.selectedLLMProvider)
        }
    }

    var selectedAnthropicModel: AnthropicModel {
        get {
            guard let raw = string(forKey: OraKey.selectedAnthropicModel),
                  let model = AnthropicModel(rawValue: raw) else {
                return .sonnet
            }
            return model
        }
        set {
            set(newValue.rawValue, forKey: OraKey.selectedAnthropicModel)
        }
    }

    var selectedOpenAIModelIdentifier: String {
        get {
            if let raw = string(forKey: OraKey.selectedOpenAIModelIdentifier),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return raw
            }
            if let legacyRaw = string(forKey: OraKey.selectedOpenAIModel),
               !legacyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return legacyRaw
            }
            return OpenAIModel.preferredDefault.rawValue
        }
        set {
            set(newValue, forKey: OraKey.selectedOpenAIModelIdentifier)
            set(newValue, forKey: OraKey.selectedOpenAIModel)
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
            guard let raw = array(forKey: OraKey.openAIDiscoveredModelIdentifiers) as? [String] else {
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
            set(deduped, forKey: OraKey.openAIDiscoveredModelIdentifiers)
        }
    }

    var openAIDiscoveredModels: [OpenAIModelOption] {
        get {
            if let data = data(forKey: OraKey.openAIDiscoveredModels),
               let decoded = try? JSONDecoder().decode([OpenAIModelOption].self, from: data) {
                return decoded
            }

            return self.openAIDiscoveredModelIdentifiers.map {
                OpenAIModelOption(identifier: $0, source: .discovered)
            }
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                set(encoded, forKey: OraKey.openAIDiscoveredModels)
            } else {
                removeObject(forKey: OraKey.openAIDiscoveredModels)
            }
            self.openAIDiscoveredModelIdentifiers = newValue.map(\.identifier)
        }
    }
}
