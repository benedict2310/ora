# C.01 - Keychain Credential Manager

**Epic:** Cloud Integrations (C)
**Status:** To Do
**Priority:** P0 (Critical Path - blocks all cloud provider stories)
**Estimated Effort:** 1-2 days
**Dependencies:** None
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Provide a secure, reusable credential storage layer using the macOS Keychain so Ora can persist API keys for cloud LLM providers (Anthropic, OpenAI, and future providers) without storing secrets in plaintext files, UserDefaults, or environment variables.

## 2. User Story

As a **user**, I want to **securely store my API keys for cloud AI providers** so that I can **use Ora with Anthropic Claude or OpenAI without re-entering keys every session, and trust that my secrets are protected by the OS**.

## 3. Scope

### In Scope
- Keychain wrapper actor for CRUD operations on API key credentials
- Support for multiple providers (keyed by provider identifier string)
- Read/write/delete operations with proper error handling
- Keychain access group scoped to Ora's bundle ID
- Unit tests with mock Keychain (protocol-based injection)

### Out of Scope
- OAuth token management (future story if needed)
- Token refresh / expiry tracking (not needed for API keys)
- iCloud Keychain sync (local-only for privacy)
- Biometric authentication for key access (macOS handles this at the Keychain level)

## 4. Architecture Alignment

### MUST REUSE
- **`Logger`** subsystem pattern (`com.ora.app`, new category `credentials`)
- **Actor isolation** pattern used throughout (ModelManager, LLMService, etc.)
- **Error enum pattern** with `LocalizedError` conformance (see `LLMServiceError`, `ModelError`)

### NEW
- **Security.framework** - `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`
- No third-party dependencies needed; Keychain Services API is sufficient

---

## Design

### Provider Credential Model

```swift
/// Identifies a cloud LLM provider
enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    /// Expected key prefix for basic validation (not a security check)
    var keyPrefix: String? {
        switch self {
        case .anthropic: return "sk-ant-"
        case .openai: return "sk-"
        }
    }
}
```

### Keychain Service Interface

```swift
/// Protocol for credential storage (enables testing with mock)
protocol CredentialStore: Sendable {
    func save(provider: CloudProvider, apiKey: String) throws
    func retrieve(provider: CloudProvider) throws -> String?
    func delete(provider: CloudProvider) throws
    func hasCredential(for provider: CloudProvider) -> Bool
}
```

### Keychain Implementation

```swift
/// Secure credential storage using macOS Keychain Services
actor KeychainCredentialStore: CredentialStore {

    private let logger = Logger(subsystem: "com.ora.app", category: "credentials")

    /// Keychain service name - scoped to Ora
    private let service = "com.ora.app.credentials"

    func save(provider: CloudProvider, apiKey: String) throws {
        // Build query
        let account = provider.rawValue
        let data = Data(apiKey.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        // Delete existing first (SecItemAdd fails on duplicate)
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.saveFailed(provider: provider, status: status)
        }

        logger.info("Saved credential for \(provider.rawValue)")
    }

    func retrieve(provider: CloudProvider) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.retrieveFailed(provider: provider, status: status)
        }

        return String(data: data, encoding: .utf8)
    }

    func delete(provider: CloudProvider) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.deleteFailed(provider: provider, status: status)
        }

        logger.info("Deleted credential for \(provider.rawValue)")
    }

    nonisolated func hasCredential(for provider: CloudProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: false,
        ]
        return SecCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
```

### Error Types

```swift
enum CredentialStoreError: LocalizedError {
    case saveFailed(provider: CloudProvider, status: OSStatus)
    case retrieveFailed(provider: CloudProvider, status: OSStatus)
    case deleteFailed(provider: CloudProvider, status: OSStatus)
    case invalidKey(provider: CloudProvider, reason: String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let provider, let status):
            return "Failed to save \(provider.displayName) API key (OSStatus: \(status))"
        case .retrieveFailed(let provider, let status):
            return "Failed to retrieve \(provider.displayName) API key (OSStatus: \(status))"
        case .deleteFailed(let provider, let status):
            return "Failed to delete \(provider.displayName) API key (OSStatus: \(status))"
        case .invalidKey(let provider, let reason):
            return "Invalid \(provider.displayName) API key: \(reason)"
        }
    }
}
```

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Cloud/CloudProvider.swift` | Provider enum and shared types |
| `Ora/Cloud/CredentialStore.swift` | Protocol + Keychain implementation |
| `OraTests/Cloud/CredentialStoreTests.swift` | Unit tests with mock store |

### 5.2 Files to Modify

None (new component, no existing file modifications needed).

### 5.3 Tests to Add

Unit tests in `OraTests/Cloud/CredentialStoreTests.swift`:
- `test_save_and_retrieve_returns_key` - Round-trip save/retrieve
- `test_retrieve_missing_returns_nil` - No key stored returns nil
- `test_save_overwrites_existing` - Second save replaces first
- `test_delete_removes_key` - Delete then retrieve returns nil
- `test_delete_nonexistent_succeeds` - Delete missing key doesn't throw
- `test_hasCredential_true_when_stored` - Boolean check works
- `test_hasCredential_false_when_missing` - Boolean check for missing
- `test_multiple_providers_independent` - Anthropic key doesn't affect OpenAI key

---

## 6. Acceptance Criteria

- [ ] **AC-1:** `CredentialStore` protocol defined with save/retrieve/delete/hasCredential
- [ ] **AC-2:** `KeychainCredentialStore` implements the protocol using Security.framework
- [ ] **AC-3:** Keys stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no iCloud sync)
- [ ] **AC-4:** `CloudProvider` enum defines `anthropic` and `openai` cases
- [ ] **AC-5:** Error types cover save/retrieve/delete failures with OSStatus codes
- [ ] **AC-6:** Unit tests pass using mock credential store
- [ ] **AC-7:** No plaintext API keys in UserDefaults, files, or logs

## 7. Verification Plan

### Automated Tests

Unit tests using `MockCredentialStore` conforming to `CredentialStore` for isolation (no real Keychain in CI):
- `test_save_and_retrieve_returns_key` - Round-trip save/retrieve
- `test_retrieve_missing_returns_nil` - No key stored returns nil
- `test_save_overwrites_existing` - Second save replaces first
- `test_delete_removes_key` - Delete then retrieve returns nil
- `test_delete_nonexistent_succeeds` - Delete missing key doesn't throw
- `test_hasCredential_true_when_stored` - Boolean check works
- `test_hasCredential_false_when_missing` - Boolean check for missing
- `test_multiple_providers_independent` - Anthropic key doesn't affect OpenAI key

Run with: `./build.sh test`

### Manual Tests

1. Build and run Ora
2. Open Preferences > Providers (once C.05 UI exists)
3. Enter an Anthropic API key, quit and relaunch, verify key persists
4. Delete the key, verify it's gone

---

## Risks and Open Questions

| Risk | Mitigation |
|:-----|:-----------|
| Keychain prompts in CI | Use `MockCredentialStore` for all tests; real Keychain only in manual testing |
| App sandbox restrictions | Keychain Services work within sandbox; no entitlement changes needed |
| Key format changes | Prefix validation is advisory only (log warning, don't reject) |
