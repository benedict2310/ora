# C.02 - Cloud Provider Abstraction

**Epic:** Cloud Integrations (C)
**Status:** To Do
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** C.01 (Keychain Credential Manager)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Introduce a provider abstraction layer that allows Ora to switch between local MLX inference and cloud LLM providers (Anthropic, OpenAI) at runtime. The key design goal is **zero changes to the agent loop, structured generator, or tool pipeline** - cloud providers plug in through the existing `LLMServicing` protocol.

## 2. User Story

As a **user**, I want to **choose between local AI models and cloud providers like Claude or GPT** so that I can **get higher-quality responses when I'm willing to use a cloud API, or stay fully local when I prefer privacy**.

## 3. Architecture Context & Reuse Guidance

### MUST REUSE
- **`LLMServicing` protocol** (`Ora/LLM/Types.swift`) - Cloud providers MUST implement this. The existing protocol signature is sufficient.
- **`StructuredGenerator`** (`Ora/LLM/StructuredGenerator.swift`) - Already accepts `LLMServicing` via init injection. No changes needed.
- **`AgentLoop`** (`Ora/Orchestration/AgentLoop.swift`) - Uses `StructuredGenerator`. No changes needed.
- **`ConversationManager`** - No changes needed.
- **`SystemPromptBuilder`** - Tool definitions are provider-agnostic JSON. No changes needed.
- **`LLMMessage` / `LLMDelta`** types - Map naturally to both Anthropic and OpenAI APIs.

### KEY INSIGHT
The existing pipeline already supports provider injection:

```
AgentLoop → StructuredGenerator(llm: LLMServicing) → llm.generate(messages:maxTokens:)
```

`StructuredGenerator` doesn't know or care whether `llm` is local MLX or a cloud API. It sends messages, gets streaming tokens back, and validates JSON. **This is the injection point.**

---

## 3. Scope

### In Scope
- `LLMProviderManager` actor for runtime provider switching
- Cloud provider base class/protocol for shared HTTP/SSE logic
- Provider resolution waterfall: explicit selection > config > environment variable > local
- Wiring into `StructuredGenerator` and `AgentLoop` via the existing `LLMServicing` injection
- Notification for provider switch events
- Fallback: if cloud fails, offer to switch to local

### Out of Scope
- Actual Anthropic/OpenAI API implementations (C.03, C.04)
- Preferences UI for switching providers (C.05)
- Multi-provider load balancing or rotation (too complex for v1)
- Native cloud tool calling APIs (use Ora's existing JSON-based tool calling for now)

---

## 4. Architecture Alignment

This story aligns with Ora's architecture by:
- Implementing the existing `LLMServicing` protocol for cloud providers
- Using dependency injection through `StructuredGenerator`
- Maintaining the agent loop without changes
- Following the actor-based concurrency model

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Cloud/LLMProviderType.swift` | Provider type enum |
| `Ora/Cloud/LLMProviderManager.swift` | Central provider switching logic |
| `Ora/Cloud/LLMProviderFactory.swift` | Factory protocol |
| `Ora/Cloud/CloudLLMBase.swift` | Shared cloud provider infrastructure |
| `Ora/Cloud/CloudProviderError.swift` | Error types for cloud providers |
| `OraTests/Cloud/LLMProviderManagerTests.swift` | Provider switching tests |

### 5.2 Files to Modify

| File | Change | Rationale |
|:-----|:-------|:----------|
| `Ora/Orchestration/AgentLoop.swift` | Accept provider from LLMProviderManager | Enable runtime provider switching |

### 5.3 Tests to Add

- Unit tests for provider switching
- Error classification tests
- Factory registration tests
- Persistence tests

### Design Details

#### Provider Manager

The central coordinator for provider lifecycle:

```swift
/// Manages active LLM provider selection and lifecycle
actor LLMProviderManager {

    static let shared = LLMProviderManager()

    private let logger = Logger(subsystem: "com.ora.app", category: "providers")
    private let credentialStore: CredentialStore

    /// Currently active provider
    private var activeProvider: LLMServicing

    /// Provider configuration
    private var selectedProviderType: LLMProviderType

    /// Available provider factories
    private var factories: [LLMProviderType: LLMProviderFactory] = [:]

    init(credentialStore: CredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
        self.activeProvider = LLMService.shared  // Default to local
        self.selectedProviderType = .local
    }

    /// Get the currently active LLM provider
    func currentProvider() -> LLMServicing {
        return activeProvider
    }

    /// Switch to a different provider
    func switchProvider(to type: LLMProviderType) async throws {
        guard type != selectedProviderType else { return }

        // Unload current if it's local
        if selectedProviderType == .local {
            await activeProvider.unload()
        }

        // Create new provider
        let provider = try await resolveProvider(type)

        activeProvider = provider
        selectedProviderType = type

        // Prepare the new provider
        try await provider.prepare()

        logger.info("Switched to provider: \(type.rawValue)")
        await postProviderChanged(type)
    }

    /// Register a provider factory
    func register(factory: LLMProviderFactory, for type: LLMProviderType) {
        factories[type] = factory
    }

    private func resolveProvider(_ type: LLMProviderType) async throws -> LLMServicing {
        switch type {
        case .local:
            return LLMService.shared
        case .anthropic, .openai:
            guard let factory = factories[type] else {
                throw ProviderError.providerNotRegistered(type)
            }
            guard let apiKey = try credentialStore.retrieve(provider: type.cloudProvider!) else {
                throw ProviderError.noCredential(type)
            }
            return try factory.create(apiKey: apiKey)
        }
    }
}
```

### Provider Types

```swift
/// Available LLM provider types
enum LLMProviderType: String, Codable, Sendable, CaseIterable {
    case local       // MLX on-device (default)
    case anthropic   // Anthropic Claude API
    case openai      // OpenAI API

    var displayName: String {
        switch self {
        case .local: return "Local (On-Device)"
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI"
        }
    }

    /// Whether this provider requires network access
    var isCloud: Bool {
        return self != .local
    }

    /// Corresponding CloudProvider for credential lookup (nil for local)
    var cloudProvider: CloudProvider? {
        switch self {
        case .local: return nil
        case .anthropic: return .anthropic
        case .openai: return .openai
        }
    }
}
```

### Provider Factory Protocol

```swift
/// Factory for creating cloud LLM provider instances
protocol LLMProviderFactory: Sendable {
    func create(apiKey: String) throws -> LLMServicing
}
```

### Cloud LLM Base

Shared infrastructure for cloud providers (SSE parsing, error handling):

```swift
/// Base class for cloud LLM providers implementing LLMServicing
///
/// Handles common concerns:
/// - SSE (Server-Sent Events) stream parsing
/// - HTTP error classification (auth, rate limit, billing)
/// - Exponential backoff on rate limits
/// - Request/response logging
actor CloudLLMBase {

    let logger: Logger
    let apiKey: String
    let session: URLSession

    init(apiKey: String, category: String) {
        self.apiKey = apiKey
        self.logger = Logger(subsystem: "com.ora.app", category: category)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - LLMServicing no-ops for cloud providers

    func warmup() async throws {
        // No-op: cloud providers don't need warmup
    }

    func prepare() async throws {
        // Subclasses can override to validate API key
    }

    func unload() async {
        // No-op: nothing to unload
    }

    func clearCache() async {
        // No-op: no local KV cache
    }

    // MARK: - SSE Parsing

    /// Parse an SSE stream from URLSession bytes
    func parseSSEStream(
        _ bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<String, Error> {
        // Implementation: buffer lines, parse "data: " prefixed lines,
        // handle [DONE] sentinel, yield text deltas
        // (Shared between Anthropic and OpenAI - both use SSE)
    }

    // MARK: - Error Classification

    /// Classify an HTTP error response
    func classifyError(statusCode: Int, body: String) -> CloudProviderError {
        switch statusCode {
        case 401: return .authenticationFailed(body)
        case 402: return .billingError(body)
        case 429: return .rateLimited(retryAfter: parseRetryAfter(body))
        case 500...599: return .serverError(statusCode: statusCode, body: body)
        default: return .requestFailed(statusCode: statusCode, body: body)
        }
    }
}
```

### Error Types

```swift
/// Errors from cloud LLM providers
enum CloudProviderError: LocalizedError {
    case authenticationFailed(String)
    case billingError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int, body: String)
    case requestFailed(statusCode: Int, body: String)
    case connectionFailed(Error)
    case invalidResponse(String)

    var errorDescription: String? { ... }

    /// Whether this error should trigger a fallback to local
    var shouldFallback: Bool {
        switch self {
        case .authenticationFailed, .billingError: return true
        case .rateLimited: return false  // Retry instead
        case .serverError, .connectionFailed: return true
        case .requestFailed, .invalidResponse: return false
        }
    }
}

/// Provider-level errors
enum ProviderError: LocalizedError {
    case providerNotRegistered(LLMProviderType)
    case noCredential(LLMProviderType)
    case switchFailed(LLMProviderType, Error)

    var errorDescription: String? { ... }
}
```

### Wiring into Existing Pipeline

The change to `AgentLoop` is minimal - it gets its `LLMServicing` from `LLMProviderManager` instead of hardcoded `LLMService.shared`:

```swift
// AgentLoop init change (the ONLY pipeline change needed):
// Before:
//   structuredGenerator: StructuredGenerator = StructuredGenerator()
//
// After:
//   The StructuredGenerator receives its LLMServicing from LLMProviderManager.
//   This can be wired at AgentLoop construction time or dynamically.
```

### Provider Selection Persistence

```swift
extension UserDefaults {
    var selectedLLMProvider: LLMProviderType {
        get {
            guard let raw = string(forKey: "com.ora.selectedLLMProvider"),
                  let type = LLMProviderType(rawValue: raw) else {
                return .local
            }
            return type
        }
        set {
            set(newValue.rawValue, forKey: "com.ora.selectedLLMProvider")
        }
    }
}
```

---

## 6. Acceptance Criteria

- [ ] **AC-1:** `LLMProviderType` enum with `.local`, `.anthropic`, `.openai` cases
- [ ] **AC-2:** `LLMProviderManager` can switch between providers at runtime
- [ ] **AC-3:** Cloud providers implement `LLMServicing` (warmup/prepare/unload/clearCache are no-ops)
- [ ] **AC-4:** `CloudLLMBase` provides shared SSE parsing and error classification
- [ ] **AC-5:** Provider selection persisted in UserDefaults
- [ ] **AC-6:** `AgentLoop`/`StructuredGenerator` work with cloud providers without code changes beyond init wiring
- [ ] **AC-7:** `CloudProviderError` classifies 401/402/429/5xx correctly

---

## 7. Verification Plan

### Automated Tests

- `test_defaultProvider_isLocal` - Fresh init uses LLMService
- `test_switchToCloud_requiresCredential` - Throws if no API key
- `test_switchToCloud_withCredential_succeeds` - Switches when key exists
- `test_switchBackToLocal_works` - Can return to local after cloud
- `test_currentProvider_returnsActive` - Returns whatever was last set
- `test_providerType_persistence` - UserDefaults round-trip
- `test_register_factory` - Factory registration and lookup

### Manual Tests

1. Start Ora with local provider (default)
2. Switch to Anthropic (with valid key in Keychain)
3. Ask a question, verify response comes from Claude
4. Switch back to local, verify response comes from Qwen

---

## Risks and Open Questions

| Risk/Question | Notes |
|:--------------|:------|
| SSE parsing complexity | Both Anthropic and OpenAI use SSE but with different payload formats. Shared line-level parsing, provider-specific JSON extraction. |
| Token counting | Cloud APIs count tokens server-side. Local uses MLX token count. `LLMDelta.completed(totalTokens:)` may need to be approximate for cloud. |
| Max tokens default | Local uses 800 tokens. Cloud models support more. May need provider-specific defaults. |
| System prompt size | Cloud APIs have much larger context windows. No changes needed but could leverage this later. |
| Concurrent provider access | `LLMProviderManager` is an actor, so switching during generation is safely serialized. |
