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
    private var codexOAuthManager: ProviderPreferencesCodexOAuthManagerMock!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")

        self.credentialStore = ProviderPreferencesCredentialStoreMock()
        self.codexOAuthManager = ProviderPreferencesCodexOAuthManagerMock()
        self.providerManager = LLMProviderManager(
            credentialStore: self.credentialStore,
            codexOAuthManager: self.codexOAuthManager
        )
        self.viewModel = ProviderPreferencesViewModel(
            credentialStore: self.credentialStore,
            providerManager: self.providerManager,
            codexOAuthManager: self.codexOAuthManager
        )
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")

        self.viewModel = nil
        self.providerManager = nil
        self.codexOAuthManager = nil
        self.credentialStore = nil
        try await super.tearDown()
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

    func test_authorizeCodex_updatesStatus() async {
        // Given
        await self.codexOAuthManager.setAuthorizeCredential(
            CodexOAuthCredential(
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "acct_123",
                accountEmail: "user@example.com",
                expiresAt: Date().addingTimeInterval(3600),
                updatedAt: Date()
            )
        )

        // When
        await self.viewModel.authorizeCodex()

        // Then
        XCTAssertEqual(
            self.viewModel.codexAuthStatus,
            .connected(account: "user@example.com")
        )
    }

    func test_disconnectCodex_clearsTokens() async throws {
        // Given
        await self.codexOAuthManager.setCurrentCredential(
            CodexOAuthCredential(
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "acct_123",
                accountEmail: "user@example.com",
                expiresAt: Date().addingTimeInterval(3600),
                updatedAt: Date()
            )
        )
        await self.viewModel.loadState()

        // When
        await self.viewModel.disconnectCodex()

        // Then
        XCTAssertEqual(self.viewModel.codexAuthStatus, .disconnected)
        let stored = try await self.codexOAuthManager.currentCredential()
        XCTAssertNil(stored)
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

private actor ProviderPreferencesCodexOAuthManagerMock: CodexOAuthManaging {
    private var current: CodexOAuthCredential?
    private var authorizeCredential: CodexOAuthCredential?

    func authorize() async throws -> CodexOAuthCredential {
        let credential = self.authorizeCredential ?? self.current
        guard let credential else {
            throw CodexOAuthError.invalidTokenResponse("No authorize credential configured")
        }
        self.current = credential
        return credential
    }

    func disconnect() async throws {
        self.current = nil
    }

    func currentCredential() async throws -> CodexOAuthCredential? {
        return self.current
    }

    func validCredentialIfAvailable() async throws -> CodexOAuthCredential? {
        return self.current
    }

    func importCLIAuthIfNeeded() async {}

    func setCurrentCredential(_ credential: CodexOAuthCredential?) {
        self.current = credential
    }

    func setAuthorizeCredential(_ credential: CodexOAuthCredential?) {
        self.authorizeCredential = credential
    }
}
