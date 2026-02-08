//
//  ProviderPreferencesViewModelTests.swift
//  OraTests
//
//  Tests for provider preferences view model behavior
//

import XCTest
@testable import Ora

@MainActor
final class ProviderPreferencesViewModelTests: XCTestCase {

    private var credentialStore: ProviderPreferencesCredentialStoreMock!
    private var providerManager: LLMProviderManager!
    private var viewModel: ProviderPreferencesViewModel!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")

        self.credentialStore = ProviderPreferencesCredentialStoreMock()
        self.providerManager = LLMProviderManager(credentialStore: self.credentialStore)
        self.viewModel = ProviderPreferencesViewModel(
            credentialStore: self.credentialStore,
            providerManager: self.providerManager
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")

        self.viewModel = nil
        self.providerManager = nil
        self.credentialStore = nil
        super.tearDown()
    }

    func test_loadState_detectsSavedKeys() async throws {
        // Given
        try await self.credentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")
        try await self.credentialStore.save(provider: .openai, apiKey: "sk-test")

        // When
        await self.viewModel.loadState()

        // Then
        XCTAssertEqual(self.viewModel.anthropicKeyStatus, .saved)
        XCTAssertEqual(self.viewModel.openAIKeyStatus, .saved)
    }

    func test_loadState_noKeys_showsNoKey() async {
        // Given

        // When
        await self.viewModel.loadState()

        // Then
        XCTAssertEqual(self.viewModel.anthropicKeyStatus, .noKey)
        XCTAssertEqual(self.viewModel.openAIKeyStatus, .noKey)
    }

    func test_saveKey_writesToKeychain() async {
        // Given
        self.viewModel.anthropicKeyInput = "sk-ant-test"

        // When
        await self.viewModel.saveAnthropicKey()

        // Then
        let saved = await self.credentialStore.retrieveOrNil(provider: .anthropic)
        XCTAssertEqual(saved, "sk-ant-test")
        XCTAssertEqual(self.viewModel.anthropicKeyStatus, .saved)
    }

    func test_deleteKey_removesFromKeychain() async throws {
        // Given
        try await self.credentialStore.save(provider: .openai, apiKey: "sk-test")
        await self.viewModel.loadState()

        // When
        await self.viewModel.deleteOpenAIKey()

        // Then
        let saved = await self.credentialStore.retrieveOrNil(provider: .openai)
        XCTAssertNil(saved)
        XCTAssertEqual(self.viewModel.openAIKeyStatus, .noKey)
    }

    func test_switchProvider_updatesManager() async throws {
        // Given
        await self.providerManager.register(factory: ProviderPreferencesMockFactory(), for: .anthropic)
        try await self.credentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")
        await self.viewModel.loadState()

        // When
        await self.viewModel.switchProvider(.anthropic)

        // Then
        let selected = await self.providerManager.getSelectedProviderType()
        XCTAssertEqual(selected, .anthropic)
        XCTAssertEqual(self.viewModel.selectedProvider, .anthropic)
    }

    func test_switchToCloud_withoutKey_showsError() async {
        // Given
        await self.providerManager.register(factory: ProviderPreferencesMockFactory(), for: .anthropic)
        await self.viewModel.loadState()

        // When
        await self.viewModel.switchProvider(.anthropic)

        // Then
        if case .error(let message) = self.viewModel.anthropicKeyStatus {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected error status")
        }

        let selected = await self.providerManager.getSelectedProviderType()
        XCTAssertEqual(selected, .local)
        XCTAssertEqual(self.viewModel.selectedProvider, .local)
    }

    func test_selectedProvider_persistedViaUserDefaults() async throws {
        // Given
        await self.providerManager.register(factory: ProviderPreferencesMockFactory(), for: .openai)
        try await self.credentialStore.save(provider: .openai, apiKey: "sk-test")
        await self.viewModel.loadState()

        // When
        await self.viewModel.switchProvider(.openai)

        // Then
        XCTAssertEqual(UserDefaults.standard.selectedLLMProvider, .openai)
    }
}

// MARK: - Mocks

actor ProviderPreferencesCredentialStoreMock: CredentialStore {
    private var storage: [CloudProvider: String] = [:]

    func save(provider: CloudProvider, apiKey: String) throws {
        self.storage[provider] = apiKey
    }

    func retrieve(provider: CloudProvider) throws -> String? {
        return self.storage[provider]
    }

    func delete(provider: CloudProvider) throws {
        self.storage.removeValue(forKey: provider)
    }

    func hasCredential(for provider: CloudProvider) -> Bool {
        return self.storage[provider] != nil
    }

    func retrieveOrNil(provider: CloudProvider) -> String? {
        return self.storage[provider]
    }
}

private struct ProviderPreferencesMockFactory: LLMProviderFactory {
    func create(apiKey: String) throws -> LLMServicing {
        return ProviderPreferencesMockProvider(apiKey: apiKey)
    }
}

private final class ProviderPreferencesMockProvider: CloudLLMBase, @unchecked Sendable {
    init(apiKey: String) {
        super.init(apiKey: apiKey, category: "provider-preferences-mock")
    }

    override func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("ok"))
            continuation.finish()
        }
    }

    override func prepare() async throws {
        // No-op for test provider
    }
}
