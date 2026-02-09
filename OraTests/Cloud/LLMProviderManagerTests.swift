//
//  LLMProviderManagerTests.swift
//  OraTests
//
//  Tests for LLM provider abstraction and switching
//

import XCTest
@testable import Ora

final class LLMProviderManagerTests: XCTestCase {

    var manager: LLMProviderManager!
    var mockCredentialStore: MockCredentialStore!
    var mockCodexOAuthManager: MockCodexOAuthManager!

    override func setUp() async throws {
        // Reset UserDefaults before manager initialization
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")

        mockCredentialStore = MockCredentialStore()
        mockCodexOAuthManager = MockCodexOAuthManager()
        manager = LLMProviderManager(
            credentialStore: mockCredentialStore,
            codexOAuthManager: mockCodexOAuthManager
        )
    }
    
    func test_defaultProvider_isLocal() async {
        let type = await manager.getSelectedProviderType()
        XCTAssertEqual(type, .local)
        
        let provider = await manager.currentProvider()
        XCTAssertTrue(provider is LLMService)
    }
    
    func test_switchToCloud_requiresCredential() async {
        // Register a mock factory
        let factory = MockProviderFactory()
        await manager.register(factory: factory, for: .anthropic)
        
        // No credential in store -> should fail
        do {
            try await manager.switchProvider(to: .anthropic)
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
        // Register factory
        let factory = MockProviderFactory()
        await manager.register(factory: factory, for: .anthropic)
        
        // Add credential
        try await mockCredentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")
        
        // Switch
        try await manager.switchProvider(to: .anthropic)
        
        // Verify
        let type = await manager.getSelectedProviderType()
        XCTAssertEqual(type, .anthropic)
        
        let provider = await manager.currentProvider()
        XCTAssertTrue(provider is MockCloudProvider)
    }
    
    func test_switchBackToLocal_works() async throws {
        // Setup cloud
        let factory = MockProviderFactory()
        await manager.register(factory: factory, for: .anthropic)
        try await mockCredentialStore.save(provider: .anthropic, apiKey: "sk-ant-test")
        try await manager.switchProvider(to: .anthropic)
        
        // Switch back
        try await manager.switchProvider(to: .local)
        
        let type = await manager.getSelectedProviderType()
        XCTAssertEqual(type, .local)
        
        let provider = await manager.currentProvider()
        XCTAssertTrue(provider is LLMService)
    }

    func test_providerType_persistence() {
        UserDefaults.standard.selectedLLMProvider = .openai
        XCTAssertEqual(UserDefaults.standard.selectedLLMProvider, .openai)
        
        UserDefaults.standard.selectedLLMProvider = .local
        XCTAssertEqual(UserDefaults.standard.selectedLLMProvider, .local)
    }

    func test_switchToOpenAI_prefersCodexCredentialWhenAvailable() async throws {
        // Given
        await manager.register(factory: MockProviderFactory(), for: .openai)
        await mockCodexOAuthManager.setCredential(
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
        try await manager.switchProvider(to: .openai)

        // Then
        let provider = await manager.currentProvider()
        XCTAssertTrue(provider is CodexProvider)
    }
}

// MARK: - Mocks

actor MockCredentialStore: CredentialStore {
    var storage: [CloudProvider: String] = [:]
    
    func save(provider: CloudProvider, apiKey: String) throws {
        storage[provider] = apiKey
    }
    
    func retrieve(provider: CloudProvider) throws -> String? {
        return storage[provider]
    }
    
    func delete(provider: CloudProvider) throws {
        storage.removeValue(forKey: provider)
    }
    
    func hasCredential(for provider: CloudProvider) -> Bool {
        return storage[provider] != nil
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
        credential = nil
    }

    func currentCredential() async throws -> CodexOAuthCredential? {
        return credential
    }

    func validCredentialIfAvailable() async throws -> CodexOAuthCredential? {
        return credential
    }

    func importCLIAuthIfNeeded() async {}

    func setCredential(_ credential: CodexOAuthCredential?) {
        self.credential = credential
    }
}

final class MockProviderFactory: LLMProviderFactory {
    func create(apiKey: String) throws -> LLMServicing {
        return MockCloudProvider(apiKey: apiKey)
    }
}

class MockCloudProvider: CloudLLMBase, @unchecked Sendable {
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
        // success
    }
}
