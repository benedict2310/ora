//
//  LLMProviderManagerTests.swift
//  OraTests
//
//  Tests for LLM provider abstraction and switching.
//

import XCTest
@testable import Ora

final class LLMProviderManagerTests: XCTestCase {

    private var manager: LLMProviderManager!
    private var mockCredentialStore: MockCredentialStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")

        self.mockCredentialStore = MockCredentialStore()
        self.manager = LLMProviderManager(credentialStore: self.mockCredentialStore)
    }

    override func tearDown() async throws {
        self.manager = nil
        self.mockCredentialStore = nil
        try await super.tearDown()
    }

    func test_defaultProvider_isLocal() async {
        let type = await self.manager.getSelectedProviderType()
        XCTAssertEqual(type, .local)

        let provider = await self.manager.currentProvider()
        XCTAssertTrue(provider is LLMService)
    }

    func test_switchToCloud_requiresCredential() async {
        let factory = MockProviderFactory()
        await self.manager.register(factory: factory, for: .anthropic)

        do {
            try await self.manager.switchProvider(to: .anthropic)
            XCTFail("Should have failed")
        } catch let error as ProviderError {
            if case .noCredential(let type) = error {
                XCTAssertEqual(type, .anthropic)
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_switchToCloud_withCredential_succeeds() async throws {
        let factory = MockProviderFactory()
        await self.manager.register(factory: factory, for: .anthropic)
        try await self.mockCredentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")

        try await self.manager.switchProvider(to: .anthropic)

        let type = await self.manager.getSelectedProviderType()
        XCTAssertEqual(type, .anthropic)

        let provider = await self.manager.currentProvider()
        XCTAssertTrue(provider is MockCloudProvider)
    }

    func test_openAIDefaultModel_usesGPT52() {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModelIdentifier")

        XCTAssertEqual(UserDefaults.standard.selectedOpenAIModelIdentifier, OpenAIModel.preferredDefault.rawValue)
    }

    func test_preflight_withMissingCredential_fallsBackToLocalWithGuidance() async {
        UserDefaults.standard.selectedLLMProvider = .openai
        let manager = LLMProviderManager(credentialStore: self.mockCredentialStore)
        await manager.register(factory: MockProviderFactory(), for: .openai)

        let preflight = await manager.preflightForConversationStart()

        if case .guidance(let message) = preflight {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected guidance preflight result")
        }

        let selected = await manager.getSelectedProviderType()
        XCTAssertEqual(selected, .local)
    }

    func test_selectedModelUnavailable_keepsAppUsableWithFallback() async throws {
        UserDefaults.standard.selectedLLMProvider = .openai
        UserDefaults.standard.selectedOpenAIModelIdentifier = "unavailable-model"
        UserDefaults.standard.openAIDiscoveredModelIdentifiers = [OpenAIModel.gpt4o.rawValue]

        let manager = LLMProviderManager(credentialStore: self.mockCredentialStore)
        try await self.mockCredentialStore.save(provider: .openai, apiKey: "sk-test")
        await manager.register(factory: MockProviderFactory(), for: .openai)

        let preflight = await manager.preflightForConversationStart()
        XCTAssertEqual(preflight, .ready)
        XCTAssertEqual(UserDefaults.standard.selectedOpenAIModelIdentifier, OpenAIModel.gpt4o.rawValue)
    }
}

// MARK: - Mocks

actor MockCredentialStore: CredentialStore {
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
}

private struct MockProviderFactory: LLMProviderFactory {
    func create(apiKey: String) throws -> LLMServicing {
        return MockCloudProvider(apiKey: apiKey)
    }
}

private final class MockCloudProvider: CloudLLMBase, @unchecked Sendable {
    init(apiKey: String) {
        super.init(apiKey: apiKey, category: "mock")
    }

    override func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("Mock"))
            continuation.finish()
        }
    }

    override func prepare() async throws {
        // No-op.
    }
}
