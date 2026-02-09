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
    @Published var openAIAvailability: OpenAIAvailability = .loading
    @Published var openAIUnavailableNote: String?

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.ora.app", category: "ProviderPreferences")
    private let credentialStore: CredentialStore
    private let providerManager: LLMProviderManager
    private let modelDiscoveryService: any OpenAIModelDiscovering

    // MARK: - Initialization

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        providerManager: LLMProviderManager = .shared,
        modelDiscoveryService: (any OpenAIModelDiscovering)? = nil
    ) {
        self.credentialStore = credentialStore
        self.providerManager = providerManager
        self.modelDiscoveryService = modelDiscoveryService ?? OpenAIModelDiscoveryService(credentialStore: credentialStore)
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

        let anthropicOptions = AnthropicModel.allCases.map { model in
            ProviderModelOption(
                provider: .anthropic,
                identifier: model.rawValue,
                displayName: model.displayName,
                isSelected: self.selectedProvider == .anthropic && self.anthropicModel == model
            )
        }

        let openAIOptions = self.openAISelectableModels.map { model in
            ProviderModelOption(
                provider: .openai,
                identifier: model.identifier,
                displayName: model.displayName,
                isSelected: self.selectedProvider == .openai && self.openAISelectedModelIdentifier == model.identifier
            )
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
            sections: [
                ProviderModelSection(provider: .local, title: "Local", options: [localOption]),
                ProviderModelSection(provider: .anthropic, title: "Anthropic", options: anthropicOptions),
                ProviderModelSection(provider: .openai, title: "OpenAI", options: openAIOptions),
            ],
            showsOpenAISetupAction: self.openAIShowsSetupAction,
            openAIUnavailableMessage: self.openAIUnavailableNote
        )
    }

    // MARK: - Public API

    func loadState() async {
        self.selectedProvider = await self.providerManager.getSelectedProviderType()
        self.anthropicModel = UserDefaults.standard.selectedAnthropicModel
        self.openAISelectedModelIdentifier = UserDefaults.standard.selectedOpenAIModelIdentifier

        await self.registerAnthropicFactory()
        await self.registerOpenAIFactory()
        await self.refreshKeyStatus(for: .anthropic)
        await self.refreshKeyStatus(for: .openai)
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
            await self.switchProvider(.local)
        }
    }

    func switchProvider(_ type: LLMProviderType) async {
        if type.isCloud {
            guard let cloudProvider = type.cloudProvider else {
                self.selectedProvider = await self.providerManager.getSelectedProviderType()
                return
            }

            do {
                let key = try await self.credentialStore.retrieve(provider: cloudProvider)
                guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.applyStatus(.error("No key configured"), for: cloudProvider)
                    self.selectedProvider = await self.providerManager.getSelectedProviderType()
                    return
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

    // MARK: - Private

    private func refreshOpenAIAvailability(forceRefresh: Bool) async {
        self.openAIAvailability = .loading

        let discoveryState = await self.modelDiscoveryService.fetchModelAvailability(forceRefresh: forceRefresh)
        switch discoveryState {
        case .available(let models, let isStale):
            await self.reconcileOpenAISelection(using: models)
            self.openAIAvailability = .available(models: models, isStale: isStale)
        case .unavailable(let reason):
            self.openAIUnavailableNote = nil
            self.openAIAvailability = .setupRequired(message: reason.recoveryMessage)
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
