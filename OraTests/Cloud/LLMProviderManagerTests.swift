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
    private var mockCodexOAuthManager: MockCodexOAuthManager!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedAnthropicModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModels")

        self.mockCredentialStore = MockCredentialStore()
        self.mockCodexOAuthManager = MockCodexOAuthManager()
        self.manager = LLMProviderManager(
            credentialStore: self.mockCredentialStore,
            codexOAuthManager: self.mockCodexOAuthManager
        )
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModels")
        self.manager = nil
        self.mockCodexOAuthManager = nil
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
        let manager = LLMProviderManager(
            credentialStore: self.mockCredentialStore,
            codexOAuthManager: self.mockCodexOAuthManager
        )
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

        let manager = LLMProviderManager(
            credentialStore: self.mockCredentialStore,
            codexOAuthManager: self.mockCodexOAuthManager
        )
        try await self.mockCredentialStore.save(provider: .openai, apiKey: "sk-test")
        await manager.register(factory: MockProviderFactory(), for: .openai)

        let preflight = await manager.preflightForConversationStart()
        XCTAssertEqual(preflight, .ready)
        XCTAssertEqual(UserDefaults.standard.selectedOpenAIModelIdentifier, OpenAIModel.gpt4o.rawValue)
    }

    func test_switchToOpenAI_prefersCodexCredentialWhenAvailable() async throws {
        // Given
        await self.manager.register(factory: MockProviderFactory(), for: .openai)
        await self.mockCodexOAuthManager.setCredential(
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
        try await self.manager.switchProvider(to: .openai)

        // Then
        let provider = await self.manager.currentProvider()
        XCTAssertTrue(provider is CodexProvider)
    }

    func test_capabilities_defaultLocalProvider_reportsVisionSupport() async {
        let capabilities = await self.manager.capabilities()
        let recommendedModel = ModelIdentifier.recommendedLocalLLM()

        XCTAssertTrue(capabilities.supportsTextInput)
        // Vision support depends on hardware — only available when recommended model supports images
        XCTAssertEqual(capabilities.supportsImageInput, recommendedModel.supportsImageInput)
    }

    func test_capabilities_passThroughFromActiveProvider() async throws {
        let factory = MockProviderFactory(capabilities: .multimodal)
        await self.manager.register(factory: factory, for: .anthropic)
        try await self.mockCredentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")

        try await self.manager.switchProvider(to: .anthropic)
        let capabilities = await self.manager.capabilities()

        XCTAssertTrue(capabilities.supportsTextInput)
        XCTAssertTrue(capabilities.supportsImageInput)
    }

    func test_capabilities_openAIWithCodexCredential_usesDiscoveredModelMetadata() async throws {
        UserDefaults.standard.selectedOpenAIModelIdentifier = "gpt-5.2-codex"
        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(
                identifier: "gpt-5.2-codex",
                source: .discovered,
                supportsImageInput: true
            ),
        ]
        await self.manager.register(factory: MockProviderFactory(), for: .openai)
        await self.mockCodexOAuthManager.setCredential(
            CodexOAuthCredential(
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "acct_123",
                accountEmail: "user@example.com",
                expiresAt: Date().addingTimeInterval(3600),
                updatedAt: Date()
            )
        )

        try await self.manager.switchProvider(to: .openai)
        let capabilities = await self.manager.capabilities()

        XCTAssertTrue(capabilities.supportsImageInput)
    }
}

/// Preparation-only tests never use application preferences or credential providers.
final class LLMPreparationProviderTests: XCTestCase {
    func test_earlyPreparation_skipsEveryCloudSelectionWithoutCredentialsOrLoad() async {
        for type in [LLMProviderType.anthropic, .openai] {
            let loader = PreparationTestLoader(suspendFirst: false)
            let local = LLMService(modelLoader: { try await loader.load($0) })
            let credentials = PreparationCredentialProbe()
            let manager = LLMProviderManager(
                credentialStore: credentials, codexOAuthManager: MockCodexOAuthManager(),
                localProvider: local, selectedProviderType: type, persistSelection: { _ in XCTFail("Unexpected preference write") }
            )
            await manager.prepareLocalIfEligible()
            let loads = await loader.count
            let lookups = await credentials.lookups
            XCTAssertEqual(loads, 0)
            XCTAssertEqual(lookups, 0)
        }
    }

    func test_earlyFailure_isIgnoredAndForegroundRetries() async throws {
        let loader = PreparationTestLoader(suspendFirst: false, failFirst: true)
        let local = LLMService(modelLoader: { try await loader.load($0) })
        let credentials = PreparationCredentialProbe()
        let manager = LLMProviderManager(
            credentialStore: credentials, codexOAuthManager: MockCodexOAuthManager(),
            localProvider: local, selectedProviderType: .local, persistSelection: { _ in XCTFail("Unexpected preference write") }
        )
        await manager.prepareLocalIfEligible()
        try await manager.prepare()
        let loads = await loader.count
        let lookups = await credentials.lookups
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(lookups, 0)
    }

    func test_providerSwitchDuringModelRetirementCannotRestartSpeculativePreparation() async throws {
        let cleanupStarted = PreparationTestSignal()
        let finishCleanup = PreparationTestSignal()
        let runtime = PreparationTestRuntime(cleanupStarted: cleanupStarted, finishCleanup: finishCleanup)
        let models = ProviderPreparationModels()
        let local = LLMService(modelLoader: { _ in await models.load(runtime) }, modelSource: { await models.read() })
        let manager = LLMProviderManager(
            credentialStore: PreparationCredentialProbe(), codexOAuthManager: MockCodexOAuthManager(),
            localProvider: local, selectedProviderType: .local, persistSelection: { _ in },
            providerResolver: { _ in MockCloudProvider(apiKey: "fake") }
        )
        try await local.prepare()
        await models.select(.qwen35_4B_Vision)
        let early = Task { await manager.prepareLocalIfEligible() }
        await cleanupStarted.wait()
        try await manager.switchProvider(to: .anthropic)
        await finishCleanup.signal()
        await early.value
        let loads = await models.loads
        XCTAssertEqual(loads, 1, "A retirement hop must not restart an obsolete speculative request")
        do {
            for try await _ in await local.generate(messages: [], maxTokens: 1) {}
            XCTFail("A model-retirement retry must retain its original eligibility")
        } catch LLMServiceError.notReady {}
    }

    func test_providerSwitchBeforeDelayedServiceEntryDoesNotResurrectLocal() async throws {
        let loader = PreparationTestLoader(suspendFirst: false)
        let local = LLMService(modelLoader: { try await loader.load($0) })
        let queued = PreparationTestSignal()
        let enter = PreparationTestSignal()
        let manager = LLMProviderManager(
            credentialStore: PreparationCredentialProbe(), codexOAuthManager: MockCodexOAuthManager(),
            localProvider: local, selectedProviderType: .local, persistSelection: { _ in },
            providerResolver: { _ in MockCloudProvider(apiKey: "fake") },
            beforeLocalPreparation: {
                await queued.signal()
                await enter.wait()
            }
        )
        let early = Task { await manager.prepareLocalIfEligible() }
        await queued.wait()
        try await manager.switchProvider(to: .anthropic)
        await enter.signal()
        await early.value
        let loads = await loader.count
        XCTAssertEqual(loads, 0, "The captured eligibility must be rechecked at service entry after unload")
        do {
            for try await _ in await local.generate(messages: [], maxTokens: 1) {}
            XCTFail("Delayed early call must not publish local readiness after cloud commit")
        } catch LLMServiceError.notReady {}
    }

    func test_providerSwitch_blocksEarlyResurrectionWhileResolutionIsSuspended() async throws {
        let loader = PreparationTestLoader()
        let local = LLMService(modelLoader: { try await loader.load($0) })
        let resolving = PreparationTestSignal()
        let resolve = PreparationTestSignal()
        let manager = LLMProviderManager(
            credentialStore: PreparationCredentialProbe(), codexOAuthManager: MockCodexOAuthManager(),
            localProvider: local, selectedProviderType: .local, persistSelection: { _ in },
            providerResolver: { _ in
                await resolving.signal()
                await resolve.wait()
                return MockCloudProvider(apiKey: "fake")
            }
        )
        let early = Task { await manager.prepareLocalIfEligible() }
        await loader.started.wait()
        let switching = Task { try await manager.switchProvider(to: .anthropic) }
        await resolving.wait()
        await manager.prepareLocalIfEligible()
        let count = await loader.count
        XCTAssertEqual(count, 1, "Transition must not permit a new speculative local flight")
        await loader.release.signal()
        await early.value
        await resolve.signal()
        try await switching.value
        let type = await manager.getSelectedProviderType()
        XCTAssertEqual(type, .anthropic)
        do {
            for try await _ in await local.generate(messages: [], maxTokens: 1) {}
            XCTFail("Switched-away local service must not become ready")
        } catch LLMServiceError.notReady {}
    }
}

private actor ProviderPreparationModels {
    private var model: ModelIdentifier = .qwen3_4B
    private(set) var loads = 0
    func read() -> ModelIdentifier { self.model }
    func select(_ model: ModelIdentifier) { self.model = model }
    func load(_ runtime: PreparationTestRuntime) -> LLMPreparedModel {
        self.loads += 1
        return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
    }
}

private actor PreparationCredentialProbe: CredentialStore {
    private(set) var lookups = 0
    func retrieve(provider: CloudProvider) throws -> String? { self.lookups += 1; return nil }
    func save(provider: CloudProvider, apiKey: String) throws { XCTFail("Unexpected credential write") }
    func delete(provider: CloudProvider) throws { XCTFail("Unexpected credential deletion") }
    func hasCredential(for provider: CloudProvider) -> Bool { self.lookups += 1; return false }
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

actor MockCodexOAuthManager: CodexOAuthManaging {
    private var credential: CodexOAuthCredential?

    func authorize() async throws -> CodexOAuthCredential {
        guard let credential else {
            throw CodexOAuthError.invalidTokenResponse("No credential")
        }
        return credential
    }

    func disconnect() async throws {
        self.credential = nil
    }

    func currentCredential() async throws -> CodexOAuthCredential? {
        return self.credential
    }

    func validCredentialIfAvailable() async throws -> CodexOAuthCredential? {
        return self.credential
    }

    func importCLIAuthIfNeeded() async {}

    func setCredential(_ credential: CodexOAuthCredential?) {
        self.credential = credential
    }
}

private struct MockProviderFactory: LLMProviderFactory {
    private let capabilities: ProviderCapabilities

    init(capabilities: ProviderCapabilities = .textOnly) {
        self.capabilities = capabilities
    }

    func create(apiKey: String) throws -> LLMServicing {
        return MockCloudProvider(apiKey: apiKey, capabilities: self.capabilities)
    }
}

private final class MockCloudProvider: CloudLLMBase, @unchecked Sendable {
    private let providerCapabilities: ProviderCapabilities

    init(apiKey: String, capabilities: ProviderCapabilities = .textOnly) {
        self.providerCapabilities = capabilities
        super.init(apiKey: apiKey, category: "mock")
    }

    override func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("Mock"))
            continuation.finish()
        }
    }

    override func capabilities() async -> ProviderCapabilities {
        return self.providerCapabilities
    }

    override func prepare() async throws {
        // No-op.
    }
}
