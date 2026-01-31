# C.04 - OpenAI Provider

**Epic:** Cloud Integrations (C)
**Status:** To Do
**Priority:** P1
**Estimated Effort:** 1-2 days
**Dependencies:** C.01 (Keychain Credential Manager), C.02 (Cloud Provider Abstraction)
**Target:** macOS 26 (Tahoe)

---

## Objective

Implement an OpenAI provider that conforms to `LLMServicing`, enabling Ora to use GPT models (GPT-4o, GPT-4o-mini, o3-mini) as its reasoning engine via the OpenAI Chat Completions API. Structurally mirrors C.03 (Anthropic) but targets OpenAI's API format.

## User Story

As a **user**, I want to **use OpenAI GPT models as my AI provider in Ora** so that I can **choose the best model for my needs while keeping all my local tools working**.

## Architecture Context & Reuse Guidance

### MUST REUSE
- **`LLMServicing`** protocol - MUST conform
- **`LLMMessage` / `LLMDelta`** types - Map to OpenAI chat format
- **`CloudLLMBase`** (from C.02) - SSE parsing, error classification
- **`KeychainCredentialStore`** (from C.01) - API key retrieval

### API Reference
- **Endpoint:** `https://api.openai.com/v1/chat/completions`
- **Auth header:** `Authorization: Bearer <key>`
- **Streaming:** SSE with `data:` lines containing JSON with `choices[0].delta.content`

---

## Scope

### In Scope
- `OpenAIProvider` actor conforming to `LLMServicing`
- Streaming Chat Completions API with SSE parsing
- Message format conversion (`LLMMessage` -> OpenAI messages)
- Model selection (gpt-4o default, configurable)
- Error handling: auth, rate limits, billing
- Retry with backoff on 429
- `OpenAIProviderFactory` for registration

### Out of Scope
- Native OpenAI function calling / tool use (future optimization)
- Assistants API
- Vision / image inputs
- Audio inputs/outputs
- Realtime API

---

## Design

### Provider Implementation

```swift
/// OpenAI provider implementing LLMServicing
actor OpenAIProvider: LLMServicing {

    private let logger = Logger(subsystem: "com.ora.app", category: "openai")
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    private let maxRetries = 2
    private let baseRetryDelay: TimeInterval = 1.0

    init(apiKey: String, model: String = "gpt-4o") {
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - LLMServicing

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamCompletion(
                        messages: messages,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func warmup() async throws { /* no-op */ }
    func prepare() async throws { /* no-op */ }
    func unload() async { /* no-op */ }
    func clearCache() async { /* no-op */ }

    // MARK: - Private

    private func streamCompletion(
        messages: [LLMMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        // OpenAI accepts system messages inline (unlike Anthropic)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages.map { msg in
                [
                    "role": msg.role == .tool ? "user" : msg.role.rawValue,
                    "content": msg.content,
                ] as [String: Any]
            },
        ]

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await streamWithRetry(request: request, continuation: continuation)
    }
}
```

### SSE Event Parsing

OpenAI SSE format:

```
data: {"id":"...","choices":[{"delta":{"role":"assistant"}}]}
data: {"id":"...","choices":[{"delta":{"content":"Hello"}}]}   ← yield as LLMDelta.token
data: {"id":"...","choices":[{"delta":{"content":" world"}}]}  ← yield as LLMDelta.token
data: {"id":"...","choices":[{"finish_reason":"stop"}],"usage":{"completion_tokens":5}}
data: [DONE]
```

```swift
private func parseOpenAISSE(
    bytes: URLSession.AsyncBytes,
    continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
) async throws {
    var tokenCount = 0

    for try await line in bytes.lines {
        guard line.hasPrefix("data: ") else { continue }
        let payload = String(line.dropFirst(6))

        if payload == "[DONE]" {
            continuation.yield(.completed(totalTokens: tokenCount))
            continuation.finish()
            return
        }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first else { continue }

        // Extract text content
        if let delta = choice["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            tokenCount += 1  // Approximate per-chunk
            continuation.yield(.token(content))
        }

        // Extract usage from final chunk (when stream_options.include_usage is true)
        if let usage = json["usage"] as? [String: Any],
           let completionTokens = usage["completion_tokens"] as? Int {
            tokenCount = completionTokens
        }
    }

    // Stream ended without [DONE]
    continuation.yield(.completed(totalTokens: tokenCount))
    continuation.finish()
}
```

### Factory and Models

```swift
struct OpenAIProviderFactory: LLMProviderFactory {
    let model: String

    init(model: String = "gpt-4o") {
        self.model = model
    }

    func create(apiKey: String) throws -> LLMServicing {
        return OpenAIProvider(apiKey: apiKey, model: model)
    }
}

enum OpenAIModel: String, Sendable, CaseIterable {
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case o3Mini = "o3-mini"

    var displayName: String {
        switch self {
        case .gpt4o: return "GPT-4o"
        case .gpt4oMini: return "GPT-4o Mini"
        case .o3Mini: return "o3-mini"
        }
    }
}
```

---

## File Touch List

| File | Action | Rationale |
|:-----|:-------|:----------|
| `Ora/Cloud/OpenAI/OpenAIProvider.swift` | Create | LLMServicing implementation for OpenAI |
| `Ora/Cloud/OpenAI/OpenAIModels.swift` | Create | Model enum and configuration |
| `Ora/Cloud/OpenAI/OpenAIProviderFactory.swift` | Create | Factory for LLMProviderManager |
| `OraTests/Cloud/OpenAI/OpenAIProviderTests.swift` | Create | Unit tests with mocked HTTP |

---

## Tests and Validation

### Unit Tests (Mocked HTTP)

- `test_generate_streams_tokens` - Mock SSE stream yields correct LLMDelta tokens
- `test_systemMessage_inlineInMessages` - System role sent in messages array (not separate)
- `test_toolRole_mappedToUser` - Tool results sent as user messages
- `test_done_sentinel_completesStream` - `[DONE]` triggers clean finish
- `test_usage_in_final_chunk` - Token count from `stream_options.include_usage`
- `test_401_throwsAuthError` - Auth failure handling
- `test_429_retriesWithBackoff` - Rate limit retry
- `test_cancelled_terminatesStream` - Task cancellation

### Manual E2E Test

1. Set OpenAI API key via Keychain
2. Switch provider to OpenAI
3. Ask "What's 2+2?" - verify GPT responds
4. Ask "What's on my calendar tomorrow?" - verify tool calling works
5. Switch between OpenAI and local, verify both work

---

## Acceptance Criteria

- [ ] **AC-1:** `OpenAIProvider` conforms to `LLMServicing`
- [ ] **AC-2:** System messages sent inline in the messages array
- [ ] **AC-3:** SSE stream parsed correctly with `[DONE]` sentinel handling
- [ ] **AC-4:** `stream_options.include_usage` enabled for accurate token counts
- [ ] **AC-5:** 429 responses trigger exponential backoff retry
- [ ] **AC-6:** 401 errors surface as `CloudProviderError.authenticationFailed`
- [ ] **AC-7:** Factory registered with `LLMProviderManager`
- [ ] **AC-8:** Tool calling works through existing `StructuredGenerator` pipeline

---

## Risks and Open Questions

| Risk/Question | Notes |
|:--------------|:------|
| OpenAI model deprecation | Models get deprecated. Need to handle gracefully (fallback to latest). |
| Tool role mapping | OpenAI has native function calling, but we use JSON-based for now. Tool results go as user messages. |
| o3-mini reasoning | o3-mini uses reasoning tokens (not visible). Token counts may include reasoning overhead. |
| `max_tokens` vs `max_completion_tokens` | Newer models use `max_completion_tokens`. May need model-specific parameter name. |
