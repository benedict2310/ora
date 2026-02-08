//
//  CredentialStoreTests.swift
//  OraTests
//
//  Tests for credential storage using mock implementation
//

import XCTest
@testable import Ora

// MARK: - Mock Implementation

/// Mock credential store for testing (no real Keychain access)
actor CredentialStoreMock: CredentialStore {
    
    private var storage: [String: String] = [:]
    
    func save(provider: CloudProvider, apiKey: String) throws {
        self.storage[provider.rawValue] = apiKey
    }
    
    func retrieve(provider: CloudProvider) throws -> String? {
        return self.storage[provider.rawValue]
    }
    
    func delete(provider: CloudProvider) throws {
        self.storage.removeValue(forKey: provider.rawValue)
    }
    
    func hasCredential(for provider: CloudProvider) -> Bool {
        return self.storage[provider.rawValue] != nil
    }
    
    func reset() {
        self.storage.removeAll()
    }
}

// MARK: - Tests

final class CredentialStoreTests: XCTestCase {
    
    var store: CredentialStoreMock!
    
    override func setUp() async throws {
        self.store = CredentialStoreMock()
    }
    
    override func tearDown() async throws {
        await self.store.reset()
        self.store = nil
    }
    
    // MARK: - Save and Retrieve Tests
    
    func test_save_and_retrieve_returns_key() async throws {
        let testKey = "sk-ant-test-key-123"
        
        try await self.store.save(provider: .anthropic, apiKey: testKey)
        let retrieved = try await self.store.retrieve(provider: .anthropic)
        
        XCTAssertEqual(retrieved, testKey)
    }
    
    func test_retrieve_missing_returns_nil() async throws {
        let retrieved = try await self.store.retrieve(provider: .anthropic)
        XCTAssertNil(retrieved)
    }
    
    func test_save_overwrites_existing() async throws {
        let firstKey = "sk-ant-first-key"
        let secondKey = "sk-ant-second-key"
        
        try await self.store.save(provider: .anthropic, apiKey: firstKey)
        try await self.store.save(provider: .anthropic, apiKey: secondKey)
        
        let retrieved = try await self.store.retrieve(provider: .anthropic)
        XCTAssertEqual(retrieved, secondKey)
    }
    
    // MARK: - Delete Tests
    
    func test_delete_removes_key() async throws {
        let testKey = "sk-ant-test-key"
        
        try await self.store.save(provider: .anthropic, apiKey: testKey)
        try await self.store.delete(provider: .anthropic)
        
        let retrieved = try await self.store.retrieve(provider: .anthropic)
        XCTAssertNil(retrieved)
    }
    
    func test_delete_nonexistent_succeeds() async throws {
        try await self.store.delete(provider: .openai)
    }
    
    // MARK: - Has Credential Tests
    
    func test_hasCredential_true_when_stored() async throws {
        let testKey = "sk-ant-test-key"
        
        try await self.store.save(provider: .anthropic, apiKey: testKey)
        
        let hasCredential = await self.store.hasCredential(for: .anthropic)
        XCTAssertTrue(hasCredential)
    }
    
    func test_hasCredential_false_when_missing() async {
        let hasCredential = await self.store.hasCredential(for: .openai)
        XCTAssertFalse(hasCredential)
    }
    
    // MARK: - Multiple Provider Tests
    
    func test_multiple_providers_independent() async throws {
        let anthropicKey = "sk-ant-anthropic-key"
        let openaiKey = "sk-openai-key"
        
        try await self.store.save(provider: .anthropic, apiKey: anthropicKey)
        try await self.store.save(provider: .openai, apiKey: openaiKey)
        
        let retrievedAnthropic = try await self.store.retrieve(provider: .anthropic)
        let retrievedOpenAI = try await self.store.retrieve(provider: .openai)
        
        XCTAssertEqual(retrievedAnthropic, anthropicKey)
        XCTAssertEqual(retrievedOpenAI, openaiKey)
        
        try await self.store.delete(provider: .anthropic)
        
        let afterDelete = try await self.store.retrieve(provider: .openai)
        XCTAssertEqual(afterDelete, openaiKey)
    }
}

// MARK: - Cloud Provider Tests

final class CloudProviderTests: XCTestCase {
    
    func test_displayName_returns_correct_values() {
        XCTAssertEqual(CloudProvider.anthropic.displayName, "Anthropic")
        XCTAssertEqual(CloudProvider.openai.displayName, "OpenAI")
    }
    
    func test_keyPrefix_returns_expected_prefixes() {
        XCTAssertEqual(CloudProvider.anthropic.keyPrefix, "sk-ant-")
        XCTAssertEqual(CloudProvider.openai.keyPrefix, "sk-")
    }
    
    func test_rawValue_is_lowercase() {
        XCTAssertEqual(CloudProvider.anthropic.rawValue, "anthropic")
        XCTAssertEqual(CloudProvider.openai.rawValue, "openai")
    }
    
    func test_caseIterable_includes_all_cases() {
        let allCases = CloudProvider.allCases
        XCTAssertEqual(allCases.count, 2)
        XCTAssertTrue(allCases.contains(.anthropic))
        XCTAssertTrue(allCases.contains(.openai))
    }
}

// MARK: - Error Tests

final class CredentialStoreErrorTests: XCTestCase {
    
    func test_saveFailed_error_message() {
        let error = CredentialStoreError.saveFailed(provider: .anthropic, status: -25300)
        XCTAssertEqual(error.errorDescription, "Failed to save Anthropic API key (OSStatus: -25300)")
    }
    
    func test_retrieveFailed_error_message() {
        let error = CredentialStoreError.retrieveFailed(provider: .openai, status: -25308)
        XCTAssertEqual(error.errorDescription, "Failed to retrieve OpenAI API key (OSStatus: -25308)")
    }
    
    func test_deleteFailed_error_message() {
        let error = CredentialStoreError.deleteFailed(provider: .anthropic, status: -25291)
        XCTAssertEqual(error.errorDescription, "Failed to delete Anthropic API key (OSStatus: -25291)")
    }
    
    func test_invalidKey_error_message() {
        let error = CredentialStoreError.invalidKey(provider: .openai, reason: "Empty string")
        XCTAssertEqual(error.errorDescription, "Invalid OpenAI API key: Empty string")
    }
}
