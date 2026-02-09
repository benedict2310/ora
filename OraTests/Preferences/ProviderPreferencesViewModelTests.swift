//
//  ProviderPreferencesViewModelTests.swift
//  OraTests
//
//  Tests for provider preferences view model behavior.
//

import XCTest
@testable import Ora

@MainActor
final class ProviderPreferencesViewModelTests: XCTestCase {

    private var credentialStore: ProviderPreferencesCredentialStoreMock!
    private var providerManager: LLMProviderManager!
    private var discoveryService: ProviderPreferencesDiscoveryServiceMock!
    private var viewModel: ProviderPreferencesViewModel!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")

        self.credentialStore = ProviderPreferencesCredentialStoreMock()
        self.providerManager = LLMProviderManager(credentialStore: self.credentialStore)
        self.discoveryService = ProviderPreferencesDiscoveryServiceMock()
        self.viewModel = ProviderPreferencesViewModel(
            credentialStore: self.credentialStore,
            providerManager: self.providerManager,
            modelDiscoveryService: self.discoveryService
        )
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")

        self.viewModel = nil
        self.discoveryService = nil
        self.providerManager = nil
        self.credentialStore = nil
        try await super.tearDown()
    }

    func test_loadState_detectsSavedKeys() async throws {
        try await self.credentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")
        try await self.credentialStore.save(provider: .openai, apiKey: "sk-test")
        await self.discoveryService.setState(
            .available(
                models: [
                    OpenAIModelOption(identifier: OpenAIModel.preferredDefault.rawValue, source: .discovered),
                ],
                isStale: false
            )
        )

        await self.viewModel.loadState()

        XCTAssertEqual(self.viewModel.anthropicKeyStatus, .saved)
        XCTAssertEqual(self.viewModel.openAIKeyStatus, .saved)
    }

    func test_loadState_openAIWithoutCredential_showsSetupRequired() async {
        await self.discoveryService.setState(.unavailable(.missingCredential))

        await self.viewModel.loadState()

        XCTAssertTrue(self.viewModel.openAIShowsSetupAction)
        XCTAssertEqual(self.viewModel.openAISelectableModels, [])
    }

    func test_loadState_openAIDefaultModel_prefersGPT52WhenAvailable() async {
        UserDefaults.standard.selectedOpenAIModelIdentifier = "unknown-model"
        await self.discoveryService.setState(
            .available(
                models: [
                    OpenAIModelOption(identifier: "gpt-4o", source: .discovered),
                    OpenAIModelOption(identifier: "gpt-5.2", source: .discovered),
                ],
                isStale: false
            )
        )

        await self.viewModel.loadState()

        XCTAssertEqual(self.viewModel.openAISelectedModelIdentifier, OpenAIModel.preferredDefault.rawValue)
    }

    func test_loadState_openAIWhenPreferredUnavailable_keepsValidSelectionAndShowsNote() async {
        UserDefaults.standard.selectedOpenAIModelIdentifier = OpenAIModel.gpt4o.rawValue
        await self.discoveryService.setState(
            .available(
                models: [
                    OpenAIModelOption(identifier: OpenAIModel.gpt4o.rawValue, source: .discovered),
                ],
                isStale: false
            )
        )

        await self.viewModel.loadState()

        XCTAssertEqual(self.viewModel.openAISelectedModelIdentifier, OpenAIModel.gpt4o.rawValue)
        XCTAssertNotNil(self.viewModel.openAIUnavailableNote)
    }

    func test_saveKey_writesToKeychain() async {
        self.viewModel.anthropicKeyInput = "sk-ant-test"

        await self.viewModel.saveAnthropicKey()

        let saved = await self.credentialStore.retrieveOrNil(provider: .anthropic)
        XCTAssertEqual(saved, "sk-ant-test")
        XCTAssertEqual(self.viewModel.anthropicKeyStatus, .saved)
    }

    func test_deleteKey_removesFromKeychain() async throws {
        try await self.credentialStore.save(provider: .openai, apiKey: "sk-test")
        await self.discoveryService.setState(.unavailable(.missingCredential))
        await self.viewModel.loadState()

        await self.viewModel.deleteOpenAIKey()

        let saved = await self.credentialStore.retrieveOrNil(provider: .openai)
        XCTAssertNil(saved)
        XCTAssertEqual(self.viewModel.openAIKeyStatus, .noKey)
    }

    func test_switchProvider_updatesManager() async throws {
        await self.providerManager.register(factory: ProviderPreferencesMockFactory(), for: .anthropic)
        try await self.credentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")
        await self.discoveryService.setState(.unavailable(.missingCredential))
        await self.viewModel.loadState()

        await self.viewModel.switchProvider(.anthropic)

        let selected = await self.providerManager.getSelectedProviderType()
        XCTAssertEqual(selected, .anthropic)
        XCTAssertEqual(self.viewModel.selectedProvider, .anthropic)
    }

    func test_switchToCloud_withoutKey_showsError() async {
        await self.providerManager.register(factory: ProviderPreferencesMockFactory(), for: .anthropic)
        await self.discoveryService.setState(.unavailable(.missingCredential))
        await self.viewModel.loadState()

        await self.viewModel.switchProvider(.anthropic)

        if case .error(let message) = self.viewModel.anthropicKeyStatus {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected error status")
        }

        let selected = await self.providerManager.getSelectedProviderType()
        XCTAssertEqual(selected, .local)
        XCTAssertEqual(self.viewModel.selectedProvider, .local)
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

actor ProviderPreferencesDiscoveryServiceMock: OpenAIModelDiscovering {
    private var state: OpenAIModelDiscoveryState = .unavailable(.missingCredential)

    func setState(_ state: OpenAIModelDiscoveryState) {
        self.state = state
    }

    func fetchModelAvailability(forceRefresh: Bool) async -> OpenAIModelDiscoveryState {
        return self.state
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
        // No-op for test provider.
    }
}
