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

    // MARK: - Published State

    @Published var selectedProvider: LLMProviderType
    @Published var anthropicKeyInput: String = ""
    @Published var openAIKeyInput: String = ""
    @Published var anthropicModel: AnthropicModel
    @Published var openAIModel: OpenAIModel
    @Published var anthropicKeyStatus: KeyStatus = .checking
    @Published var openAIKeyStatus: KeyStatus = .checking
    @Published var codexAuthStatus: CodexAuthStatus = .disconnected

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.ora.app", category: "ProviderPreferences")
    private let credentialStore: CredentialStore
    private let providerManager: LLMProviderManager
    private let codexOAuthManager: CodexOAuthManaging

    // MARK: - Initialization

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        providerManager: LLMProviderManager = .shared,
        codexOAuthManager: CodexOAuthManaging = CodexOAuthManager.shared
    ) {
        self.credentialStore = credentialStore
        self.providerManager = providerManager
        self.codexOAuthManager = codexOAuthManager
        self.selectedProvider = UserDefaults.standard.selectedLLMProvider
        self.anthropicModel = UserDefaults.standard.selectedAnthropicModel
        self.openAIModel = UserDefaults.standard.selectedOpenAIModel
    }

    // MARK: - Public API

    func loadState() async {
        self.selectedProvider = await self.providerManager.getSelectedProviderType()
        self.anthropicModel = UserDefaults.standard.selectedAnthropicModel
        self.openAIModel = UserDefaults.standard.selectedOpenAIModel

        await self.codexOAuthManager.importCLIAuthIfNeeded()
        await self.registerAnthropicFactory()
        await self.registerOpenAIFactory()
        await self.refreshKeyStatus(for: .anthropic)
        await self.refreshKeyStatus(for: .openai)
        await self.refreshCodexStatus()
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
                    guard let key, !key.isEmpty else {
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
            factory: OpenAIProviderFactory(model: self.openAIModel.rawValue),
            for: .openai
        )
    }
}
