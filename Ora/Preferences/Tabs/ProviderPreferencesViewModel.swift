//
//  ProviderPreferencesViewModel.swift
//  Ora
//
//  View model for cloud provider configuration in Preferences
//

import Foundation
import os

@MainActor
final class ProviderPreferencesViewModel: ObservableObject {

    // MARK: - Key Status

    enum KeyStatus: Equatable {
        case noKey
        case saved
        case checking
        case error(String)
    }

    enum CodexAuthStatus: Equatable {
        case disconnected
        case connecting
        case connected(account: String)
        case error(String)

        var isConnected: Bool {
            if case .connected = self {
                return true
            }
            return false
        }
    }

    // MARK: - OpenAI Availability

    enum OpenAIAvailability: Equatable {
        case loading
        case available(models: [OpenAIModelOption], isStale: Bool)
        case setupRequired(message: String)
    }

    // MARK: - Published State

    @Published var selectedProvider: LLMProviderType
    @Published var anthropicKeyInput: String = ""
    @Published var openAIKeyInput: String = ""
    @Published var anthropicModel: AnthropicModel
    @Published var openAISelectedModelIdentifier: String
    @Published var anthropicKeyStatus: KeyStatus = .checking
    @Published var openAIKeyStatus: KeyStatus = .checking
    @Published var codexAuthStatus: CodexAuthStatus = .disconnected
    @Published var openAIAvailability: OpenAIAvailability = .loading
    @Published var openAIUnavailableNote: String?

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.ora.app", category: "ProviderPreferences")
    private let credentialStore: CredentialStore
    private let providerManager: LLMProviderManager
    private let codexOAuthManager: CodexOAuthManaging
    private let modelDiscoveryService: any OpenAIModelDiscovering

    // MARK: - Initialization

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        providerManager: LLMProviderManager = .shared,
        codexOAuthManager: CodexOAuthManaging = CodexOAuthManager.shared,
        modelDiscoveryService: (any OpenAIModelDiscovering)? = nil
    ) {
        self.credentialStore = credentialStore
        self.providerManager = providerManager
        self.codexOAuthManager = codexOAuthManager
        self.modelDiscoveryService = modelDiscoveryService ?? OpenAIModelDiscoveryService(
            credentialStore: credentialStore,
            codexOAuthManager: codexOAuthManager
        )
        self.selectedProvider = UserDefaults.standard.selectedLLMProvider
        self.anthropicModel = UserDefaults.standard.selectedAnthropicModel
        self.openAISelectedModelIdentifier = UserDefaults.standard.selectedOpenAIModelIdentifier
    }

    // MARK: - Computed

    var openAISelectableModels: [OpenAIModelOption] {
        if case .available(let models, _) = self.openAIAvailability {
            return models
        }
        return []
    }

    var openAIShowsSetupAction: Bool {
        if case .setupRequired = self.openAIAvailability {
            return true
        }
        return false
    }

    var selectedOpenAIModelDisplayName: String {
        return OpenAIModel.displayName(for: self.openAISelectedModelIdentifier)
    }

    var modelSelectionMenuState: ModelSelectionMenuState {
        let localOption = ProviderModelOption(
            provider: .local,
            identifier: ModelIdentifier.qwen3_4B.rawValue,
            displayName: ModelIdentifier.qwen3_4B.displayName,
            isSelected: self.selectedProvider == .local
        )

        var sections: [ProviderModelSection] = [
            ProviderModelSection(provider: .local, title: "Local", options: [localOption]),
        ]

        // Only show Anthropic section if credentials are configured
        if self.anthropicKeyStatus == .saved {
            let anthropicOptions = AnthropicModel.allCases.map { model in
                ProviderModelOption(
                    provider: .anthropic,
                    identifier: model.rawValue,
                    displayName: model.displayName,
                    isSelected: self.selectedProvider == .anthropic && self.anthropicModel == model
                )
            }
            sections.append(ProviderModelSection(provider: .anthropic, title: "Anthropic", options: anthropicOptions))
        }

        // Only show OpenAI section if API key saved or Codex connected
        let hasOpenAICredentials = self.openAIKeyStatus == .saved || self.codexAuthStatus.isConnected
        if hasOpenAICredentials {
            let openAIOptions = self.openAISelectableModels.map { model in
                ProviderModelOption(
                    provider: .openai,
                    identifier: model.identifier,
                    displayName: model.displayName,
                    isSelected: self.selectedProvider == .openai && self.openAISelectedModelIdentifier == model.identifier
                )
            }
            if !openAIOptions.isEmpty {
                sections.append(ProviderModelSection(provider: .openai, title: "OpenAI", options: openAIOptions))
            }
        }

        var setupRequiredProviders: [LLMProviderType] = []
        if self.anthropicKeyStatus != .saved {
            setupRequiredProviders.append(.anthropic)
        }
        if !hasOpenAICredentials {
            setupRequiredProviders.append(.openai)
        }

        let activeModelName: String
        switch self.selectedProvider {
        case .local:
            activeModelName = ModelIdentifier.qwen3_4B.displayName
        case .anthropic:
            activeModelName = self.anthropicModel.displayName
        case .openai:
            activeModelName = self.selectedOpenAIModelDisplayName
        }

        return ModelSelectionMenuState(
            activeProvider: self.selectedProvider,
            activeModelDisplayName: activeModelName,
            sections: sections,
            setupRequiredProviders: setupRequiredProviders,
            showsOpenAISetupAction: self.openAIShowsSetupAction,
            openAIUnavailableMessage: self.openAIUnavailableNote
        )
    }

    // MARK: - Public API

    func loadState() async {
        self.selectedProvider = await self.providerManager.getSelectedProviderType()
        self.anthropicModel = UserDefaults.standard.selectedAnthropicModel
        self.openAISelectedModelIdentifier = UserDefaults.standard.selectedOpenAIModelIdentifier

        await self.codexOAuthManager.importCLIAuthIfNeeded()
        await self.registerAnthropicFactory()
        await self.registerOpenAIFactory()
        await self.refreshKeyStatus(for: .anthropic)
        await self.refreshKeyStatus(for: .openai)
        await self.refreshCodexStatus()
        await self.refreshOpenAIAvailability(forceRefresh: false)
    }

    func refreshModelAvailability(forceRefresh: Bool = false) async {
        await self.refreshOpenAIAvailability(forceRefresh: forceRefresh)
    }

    func saveAnthropicKey() async {
        await self.saveKey(input: self.anthropicKeyInput, for: .anthropic)
        self.anthropicKeyInput = ""

        if self.selectedProvider == .anthropic {
            await self.reconnectSelectedProvider(.anthropic)
        }
    }

    func saveOpenAIKey() async {
        await self.saveKey(input: self.openAIKeyInput, for: .openai)
        self.openAIKeyInput = ""
        await self.refreshOpenAIAvailability(forceRefresh: true)

        if self.selectedProvider == .openai {
            await self.reconnectSelectedProvider(.openai)
        }
    }

    func deleteAnthropicKey() async {
        await self.deleteKey(for: .anthropic)

        if self.selectedProvider == .anthropic {
            await self.switchProvider(.local)
        }
    }

    func deleteOpenAIKey() async {
        await self.deleteKey(for: .openai)
        self.openAIAvailability = .setupRequired(message: "Set up OpenAI to browse models.")

        if self.selectedProvider == .openai {
            if self.codexAuthStatus.isConnected {
                await self.reconnectSelectedProvider(.openai)
            } else {
                await self.switchProvider(.local)
            }
        }
    }

    func authorizeCodex() async {
        self.codexAuthStatus = .connecting

        do {
            let credential = try await self.codexOAuthManager.authorize()
            self.codexAuthStatus = .connected(account: credential.displayIdentifier)
            if self.selectedProvider == .openai {
                await self.reconnectSelectedProvider(.openai)
            }
        } catch {
            self.logger.error("Codex authorization failed: \(error.localizedDescription)")
            self.codexAuthStatus = .error(error.localizedDescription)
        }
    }

    func disconnectCodex() async {
        do {
            try await self.codexOAuthManager.disconnect()
            self.codexAuthStatus = .disconnected

            if self.selectedProvider == .openai {
                if self.openAIKeyStatus == .saved {
                    await self.reconnectSelectedProvider(.openai)
                } else {
                    await self.switchProvider(.local)
                }
            }
        } catch {
            self.logger.error("Failed to disconnect Codex OAuth: \(error.localizedDescription)")
            self.codexAuthStatus = .error(error.localizedDescription)
        }
    }

    func switchProvider(_ type: LLMProviderType) async {
        if type.isCloud {
            guard let cloudProvider = type.cloudProvider else {
                self.selectedProvider = await self.providerManager.getSelectedProviderType()
                return
            }

            do {
                if type == .openai {
                    guard try await self.hasOpenAICredential() else {
                        self.applyStatus(.error("No key configured"), for: .openai)
                        self.selectedProvider = await self.providerManager.getSelectedProviderType()
                        return
                    }
                } else {
                    let key = try await self.credentialStore.retrieve(provider: cloudProvider)
                    guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.applyStatus(.error("No key configured"), for: cloudProvider)
                        self.selectedProvider = await self.providerManager.getSelectedProviderType()
                        return
                    }
                }
            } catch {
                self.applyStatus(.error(error.localizedDescription), for: cloudProvider)
                self.selectedProvider = await self.providerManager.getSelectedProviderType()
                return
            }
        }

        do {
            try await self.providerManager.switchProvider(to: type)
            self.selectedProvider = type
            if type == .openai {
                await self.refreshOpenAIAvailability(forceRefresh: true)
            }
        } catch {
            if let cloudProvider = type.cloudProvider {
                self.applyStatus(.error(error.localizedDescription), for: cloudProvider)
            }
            self.selectedProvider = await self.providerManager.getSelectedProviderType()
        }
    }

    func selectModel(provider: LLMProviderType, identifier: String) async {
        switch provider {
        case .local:
            await self.switchProvider(.local)
        case .anthropic:
            guard let model = AnthropicModel(rawValue: identifier) else {
                return
            }
            await self.updateAnthropicModel(model)
            await self.switchProvider(.anthropic)
        case .openai:
            await self.updateOpenAIModel(identifier)
            await self.switchProvider(.openai)
        }
    }

    func updateAnthropicModel(_ model: AnthropicModel) async {
        self.anthropicModel = model
        UserDefaults.standard.selectedAnthropicModel = model
        await self.registerAnthropicFactory()

        if self.selectedProvider == .anthropic {
            await self.reconnectSelectedProvider(.anthropic)
        }
    }

    func updateOpenAIModel(_ identifier: String) async {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.openAISelectedModelIdentifier = trimmed
        UserDefaults.standard.selectedOpenAIModelIdentifier = trimmed
        await self.registerOpenAIFactory()

        if self.selectedProvider == .openai {
            await self.reconnectSelectedProvider(.openai)
        }
    }

    var openAICredentialSummary: String {
        if self.codexAuthStatus.isConnected && self.openAIKeyStatus == .saved {
            return "Active credential: Codex OAuth (API key fallback available)"
        }
        if self.codexAuthStatus.isConnected {
            return "Active credential: Codex OAuth"
        }
        if self.openAIKeyStatus == .saved {
            return "Active credential: API key"
        }
        return "Active credential: None"
    }

    // MARK: - Private

    private func hasOpenAICredential() async throws -> Bool {
        if let _ = try await self.codexOAuthManager.validCredentialIfAvailable() {
            return true
        }
        let key = try await self.credentialStore.retrieve(provider: .openai)
        return key?.isEmpty == false
    }

    private func refreshCodexStatus() async {
        do {
            if let credential = try await self.codexOAuthManager.validCredentialIfAvailable() {
                self.codexAuthStatus = .connected(account: credential.displayIdentifier)
            } else {
                self.codexAuthStatus = .disconnected
            }
        } catch {
            self.codexAuthStatus = .error(error.localizedDescription)
        }
    }

    private func refreshOpenAIAvailability(forceRefresh: Bool) async {
        self.openAIAvailability = .loading

        let discoveryState = await self.modelDiscoveryService.fetchModelAvailability(forceRefresh: forceRefresh)
        switch discoveryState {
        case .available(let models, let isStale):
            await self.reconcileOpenAISelection(using: models)
            self.openAIAvailability = .available(models: models, isStale: isStale)
        case .unavailable(let reason):
            if self.codexAuthStatus.isConnected {
                let curatedModels = Self.codexFallbackModelOptions
                await self.reconcileOpenAISelection(using: curatedModels)
                self.openAIAvailability = .available(models: curatedModels, isStale: true)
                self.openAIUnavailableNote = "Could not refresh remote model list (\(reason.recoveryMessage)). Showing default models."
            } else {
                self.openAIUnavailableNote = nil
                self.openAIAvailability = .setupRequired(message: reason.recoveryMessage)
            }
        }
    }

    private func reconcileOpenAISelection(using discoveredModels: [OpenAIModelOption]) async {
        let discoveredIDs = Set(discoveredModels.map(\.identifier))
        let currentSelection = self.openAISelectedModelIdentifier

        if discoveredIDs.contains(currentSelection) {
            self.openAIUnavailableNote = discoveredIDs.contains(OpenAIModel.preferredDefault.rawValue)
                ? nil
                : "\(OpenAIModel.preferredDefault.displayName) is not currently available for this account."
            return
        }

        if discoveredIDs.contains(OpenAIModel.preferredDefault.rawValue) {
            await self.updateOpenAIModel(OpenAIModel.preferredDefault.rawValue)
            self.openAIUnavailableNote = nil
            return
        }

        guard let fallbackModel = discoveredModels.first else {
            self.openAIUnavailableNote = nil
            return
        }

        await self.updateOpenAIModel(fallbackModel.identifier)
        self.openAIUnavailableNote = "\(OpenAIModel.preferredDefault.displayName) is not currently available for this account."
    }

    private func saveKey(input: String, for provider: CloudProvider) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.applyStatus(.error("API key cannot be empty"), for: provider)
            return
        }

        do {
            try await self.credentialStore.save(provider: provider, apiKey: trimmed)
            self.applyStatus(.saved, for: provider)
        } catch {
            self.logger.error("Failed to save key for provider \(provider.rawValue): \(error.localizedDescription)")
            self.applyStatus(.error(error.localizedDescription), for: provider)
        }
    }

    private func deleteKey(for provider: CloudProvider) async {
        do {
            try await self.credentialStore.delete(provider: provider)
            self.applyStatus(.noKey, for: provider)
        } catch {
            self.logger.error("Failed to delete key for provider \(provider.rawValue): \(error.localizedDescription)")
            self.applyStatus(.error(error.localizedDescription), for: provider)
        }
    }

    private func reconnectSelectedProvider(_ type: LLMProviderType) async {
        do {
            try await self.providerManager.switchProvider(to: type)
            self.selectedProvider = type
        } catch {
            if let cloudProvider = type.cloudProvider {
                self.applyStatus(.error(error.localizedDescription), for: cloudProvider)
            }
            self.selectedProvider = await self.providerManager.getSelectedProviderType()
        }
    }

    private func refreshKeyStatus(for provider: CloudProvider) async {
        self.applyStatus(.checking, for: provider)

        do {
            let key = try await self.credentialStore.retrieve(provider: provider)
            if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.applyStatus(.saved, for: provider)
            } else {
                self.applyStatus(.noKey, for: provider)
            }
        } catch {
            self.applyStatus(.error(error.localizedDescription), for: provider)
        }
    }

    private func applyStatus(_ status: KeyStatus, for provider: CloudProvider) {
        switch provider {
        case .anthropic:
            self.anthropicKeyStatus = status
        case .openai:
            self.openAIKeyStatus = status
        case .openaiCodex:
            break
        }
    }

    private func registerAnthropicFactory() async {
        await self.providerManager.register(
            factory: AnthropicProviderFactory(model: self.anthropicModel.rawValue),
            for: .anthropic
        )
    }

    private func registerOpenAIFactory() async {
        await self.providerManager.register(
            factory: OpenAIProviderFactory(model: self.openAISelectedModelIdentifier),
            for: .openai
        )
    }

    private static var codexFallbackModelOptions: [OpenAIModelOption] {
        var options: [OpenAIModelOption] = [
            OpenAIModelOption(identifier: "gpt-5.2-codex", source: .curated),
        ]
        options.append(contentsOf: OpenAIModel.curatedOptions)

        var seen: Set<String> = []
        return options.filter { option in
            if seen.contains(option.identifier) {
                return false
            }
            seen.insert(option.identifier)
            return true
        }
    }
}

// MARK: - Discovery Messages

private extension OpenAIModelDiscoveryUnavailableReason {
    var recoveryMessage: String {
        switch self {
        case .missingCredential:
            return "Set up OpenAI to browse models."
        case .disconnected:
            return "OpenAI is currently unreachable. Set up connection to continue."
        case .unauthorized:
            return "OpenAI credential is invalid. Set up connection to continue."
        case .requestFailed(let message):
            return "OpenAI model discovery failed: \(message)"
        }
    }
}
