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

    override func setUp() async throws {
        mockCredentialStore = MockCredentialStore()
        manager = LLMProviderManager(credentialStore: mockCredentialStore)
        
        // Reset UserDefaults
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
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

final class MockProviderFactory: LLMProviderFactory {
    func create(apiKey: String) throws -> LLMServicing {
        return MockCloudProvider(apiKey: apiKey)
    }
}

class MockCloudProvider: CloudLLMBase {
    override init(apiKey: String, category: String = "mock") {
        super.init(apiKey: apiKey, category: category)
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
