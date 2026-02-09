//
//  CredentialStore.swift
//  Ora
//
//  Secure credential storage using macOS Keychain Services
//

import Foundation
import Security
import os

// MARK: - Protocol

/// Protocol for credential storage (enables testing with mock)
protocol CredentialStore: Actor {
    func save(provider: CloudProvider, apiKey: String) throws
    func retrieve(provider: CloudProvider) throws -> String?
    func delete(provider: CloudProvider) throws
    func hasCredential(for provider: CloudProvider) -> Bool
}

// MARK: - Error Types

enum CredentialStoreError: LocalizedError {
    case saveFailed(provider: CloudProvider, status: OSStatus)
    case retrieveFailed(provider: CloudProvider, status: OSStatus)
    case deleteFailed(provider: CloudProvider, status: OSStatus)
    case invalidKey(provider: CloudProvider, reason: String)
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let provider, let status):
            return "Failed to save \(provider.displayName) credential (OSStatus: \(status))"
        case .retrieveFailed(let provider, let status):
            return "Failed to retrieve \(provider.displayName) credential (OSStatus: \(status))"
        case .deleteFailed(let provider, let status):
            return "Failed to delete \(provider.displayName) credential (OSStatus: \(status))"
        case .invalidKey(let provider, let reason):
            return "Invalid \(provider.displayName) credential: \(reason)"
        }
    }
}

// MARK: - Keychain Implementation

/// Secure credential storage using macOS Keychain Services
actor KeychainCredentialStore: CredentialStore {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "credentials")
    
    /// Keychain service name - scoped to Ora
    private static let service = "com.ora.app.credentials"
    
    // MARK: - Public API
    
    func save(provider: CloudProvider, apiKey: String) throws {
        let account = provider.rawValue
        let data = Data(apiKey.utf8)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        
        // Delete existing first (SecItemAdd fails on duplicate)
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            self.logger.error("Failed to save credential for \(account): OSStatus \(status)")
            throw CredentialStoreError.saveFailed(provider: provider, status: status)
        }
        
        self.logger.info("Saved credential for \(account)")
    }
    
    func retrieve(provider: CloudProvider) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess, let data = result as? Data else {
            self.logger.error("Failed to retrieve credential for \(provider.rawValue): OSStatus \(status)")
            throw CredentialStoreError.retrieveFailed(provider: provider, status: status)
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    func delete(provider: CloudProvider) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            self.logger.error("Failed to delete credential for \(provider.rawValue): OSStatus \(status)")
            throw CredentialStoreError.deleteFailed(provider: provider, status: status)
        }
        
        self.logger.info("Deleted credential for \(provider.rawValue)")
    }
    
    nonisolated func hasCredential(for provider: CloudProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: false,
        ]
        
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
