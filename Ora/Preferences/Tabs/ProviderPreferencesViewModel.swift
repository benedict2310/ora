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

    // MARK: - Published State

    @Published var selectedProvider: LLMProviderType
    @Published var anthropicKeyInput: String = ""
    @Published var openAIKeyInput: String = ""
    @Published var anthropicModel: AnthropicModel
    @Published var openAIModel: OpenAIModel
    @Published var anthropicKeyStatus: KeyStatus = .checking
    @Published var openAIKeyStatus: KeyStatus = .checking

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.ora.app", category: "ProviderPreferences")
    private let credentialStore: CredentialStore
    private let providerManager: LLMProviderManager

    // MARK: - Initialization

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        providerManager: LLMProviderManager = .shared
    ) {
        self.credentialStore = credentialStore
        self.providerManager = providerManager
        self.selectedProvider = UserDefaults.standard.selectedLLMProvider
        self.anthropicModel = UserDefaults.standard.selectedAnthropicModel
        self.openAIModel = UserDefaults.standard.selectedOpenAIModel
    }

    // MARK: - Public API

    func loadState() async {
        self.selectedProvider = await self.providerManager.getSelectedProviderType()
        self.anthropicModel = UserDefaults.standard.selectedAnthropicModel
        self.openAIModel = UserDefaults.standard.selectedOpenAIModel

        await self.registerAnthropicFactory()
        await self.registerOpenAIFactory()
        await self.refreshKeyStatus(for: .anthropic)
        await self.refreshKeyStatus(for: .openai)
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
                guard let key, !key.isEmpty else {
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
        } catch {
            if let cloudProvider = type.cloudProvider {
                self.applyStatus(.error(error.localizedDescription), for: cloudProvider)
            }
            self.selectedProvider = await self.providerManager.getSelectedProviderType()
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

    func updateOpenAIModel(_ model: OpenAIModel) async {
        self.openAIModel = model
        UserDefaults.standard.selectedOpenAIModel = model
        await self.registerOpenAIFactory()

        if self.selectedProvider == .openai {
            await self.reconnectSelectedProvider(.openai)
        }
    }

    // MARK: - Private

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
            if let key, !key.isEmpty {
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
            factory: OpenAIProviderFactory(model: self.openAIModel.rawValue),
            for: .openai
        )
    }
}
