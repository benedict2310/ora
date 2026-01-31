# C.03 - Anthropic Claude Provider

**Epic:** Cloud Integrations (C)
**Status:** To Do
**Priority:** P1
**Estimated Effort:** 2-3 days
**Dependencies:** C.01 (Keychain Credential Manager), C.02 (Cloud Provider Abstraction)
**Target:** macOS 26 (Tahoe)

---

## Objective

Implement an Anthropic Claude provider that conforms to `LLMServicing`, enabling Ora to use Claude (Sonnet/Haiku/Opus) as its reasoning engine via the Anthropic Messages API. The provider streams tokens through Ora's existing pipeline - the agent loop, structured generator, and tool system work unchanged.

## User Story

As a **user**, I want to **use Anthropic Claude as my AI provider in Ora** so that I can **get high-quality responses powered by Claude while keeping all my local tools (calendar, reminders, contacts) working**.

## Architecture Context & Reuse Guidance

### MUST REUSE
- **`LLMServicing`** protocol - MUST conform to this
- **`LLMMessage` / `LLMDelta`** types - Map to Anthropic Messages API format
- **`CloudLLMBase`** (from C.02) - SSE parsing, error handling, HTTP session
- **`KeychainCredentialStore`** (from C.01) - API key retrieval

### API Reference
- **Endpoint:** `https://api.anthropic.com/v1/messages`
- **Auth header:** `x-api-key: <key>`
- **Streaming:** SSE with `event: content_block_delta` carrying text deltas
- **Version header:** `anthropic-version: 2023-06-01`

---

## Scope

### In Scope
- `AnthropicProvider` actor conforming to `LLMServicing`
- Streaming Messages API integration with SSE parsing
- Message format conversion (`LLMMessage` -> Anthropic messages format)
- Model selection (claude-sonnet-4-20250514 default, configurable)
- Error handling: auth failures, rate limits, billing errors
- Retry with exponential backoff on 429 (rate limit)
- `AnthropicProviderFactory` for registration with `LLMProviderManager`

### Out of Scope
- Native Anthropic tool use API (future optimization - Ora's JSON-based tool calling works fine)
- Anthropic Batch API
- Vision/multimodal inputs
- OAuth authentication (API key only for v1)
- Prompt caching / extended thinking

---

## Design

### Provider Implementation

```swift
/// Anthropic Claude provider implementing LLMServicing
actor AnthropicProvider: LLMServicing {

    private let logger = Logger(subsystem: "com.ora.app", category: "anthropic")
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    // Retry configuration
    private let maxRetries = 2
    private let baseRetryDelay: TimeInterval = 1.0

    init(apiKey: String, model: String = "claude-sonnet-4-20250514") {
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
    func prepare() async throws { /* could validate key with a lightweight call */ }
    func unload() async { /* no-op */ }
    func clearCache() async { /* no-op */ }

    // MARK: - Private

    private func streamCompletion(
        messages: [LLMMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        // Separate system message from conversation messages
        let systemText = messages.first { $0.role == .system }?.content
        let conversationMessages = messages.filter { $0.role != .system }

        // Build request body
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": conversationMessages.map { msg in
                [
                    "role": msg.role == .tool ? "user" : msg.role.rawValue,
                    "content": msg.content,
                ] as [String: Any]
            },
        ]
        if let system = systemText {
            body["system"] = system
        }

        // Build request
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Stream response with retry
        try await streamWithRetry(request: request, continuation: continuation)
    }
}
```

### SSE Event Parsing

Anthropic SSE events relevant to streaming:

```
event: message_start       → Contains model, usage info
event: content_block_start → Content block begins
event: content_block_delta → {"type":"text_delta","text":"Hello"}  ← yield as LLMDelta.token
event: content_block_stop  → Content block ends
event: message_delta       → Contains stop_reason, usage
event: message_stop        → Stream complete → yield LLMDelta.completed
```

```swift
/// Parse Anthropic SSE events into LLMDelta values
private func parseAnthropicSSE(
    bytes: URLSession.AsyncBytes,
    continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
) async throws {
    var tokenCount = 0
    var buffer = ""

    for try await line in bytes.lines {
        if line.hasPrefix("data: ") {
            let json = String(line.dropFirst(6))
            guard let data = json.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    tokenCount += 1  // Approximate
                    continuation.yield(.token(text))
                }
            case "message_delta":
                // Extract usage if available
                if let usage = event["usage"] as? [String: Any],
                   let outputTokens = usage["output_tokens"] as? Int {
                    tokenCount = outputTokens
                }
            case "message_stop":
                continuation.yield(.completed(totalTokens: tokenCount))
                continuation.finish()
                return
            case "error":
                if let error = event["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw CloudProviderError.requestFailed(
                        statusCode: 0, body: message
                    )
                }
            default:
                break
            }
        }
    }

    // Stream ended without message_stop
    continuation.yield(.completed(totalTokens: tokenCount))
    continuation.finish()
}
```

### Retry Logic

```swift
private func streamWithRetry(
    request: URLRequest,
    continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
) async throws {
    var lastError: Error?

    for attempt in 0...maxRetries {
        if attempt > 0 {
            let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
            logger.info("Retrying after \(delay)s (attempt \(attempt + 1))")
            try await Task.sleep(for: .seconds(delay))
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudProviderError.invalidResponse("Non-HTTP response")
            }

            guard httpResponse.statusCode == 200 else {
                // Collect error body
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }

                let error = classifyError(
                    statusCode: httpResponse.statusCode, body: errorBody
                )

                // Only retry on rate limit
                if case .rateLimited = error, attempt < maxRetries {
                    lastError = error
                    continue
                }
                throw error
            }

            // Success - parse the stream
            try await parseAnthropicSSE(bytes: bytes, continuation: continuation)
            return

        } catch let error as CloudProviderError {
            if case .rateLimited = error, attempt < maxRetries {
                lastError = error
                continue
            }
            throw error
        } catch {
            throw CloudProviderError.connectionFailed(error)
        }
    }

    throw lastError ?? CloudProviderError.requestFailed(statusCode: 0, body: "Max retries exceeded")
}
```

### Factory

```swift
struct AnthropicProviderFactory: LLMProviderFactory {
    let model: String

    init(model: String = "claude-sonnet-4-20250514") {
        self.model = model
    }

    func create(apiKey: String) throws -> LLMServicing {
        return AnthropicProvider(apiKey: apiKey, model: model)
    }
}
```

### Anthropic Model Options

```swift
enum AnthropicModel: String, Sendable, CaseIterable {
    case sonnet = "claude-sonnet-4-20250514"
    case haiku = "claude-haiku-4-20250514"
    case opus = "claude-opus-4-20250514"

    var displayName: String {
        switch self {
        case .sonnet: return "Claude Sonnet 4"
        case .haiku: return "Claude Haiku 4"
        case .opus: return "Claude Opus 4"
        }
    }

    var maxOutputTokens: Int {
        switch self {
        case .sonnet: return 8192
        case .haiku: return 8192
        case .opus: return 8192
        }
    }
}
```

---

## File Touch List

| File | Action | Rationale |
|:-----|:-------|:----------|
| `Ora/Cloud/Anthropic/AnthropicProvider.swift` | Create | LLMServicing implementation for Anthropic |
| `Ora/Cloud/Anthropic/AnthropicModels.swift` | Create | Model enum and configuration |
| `Ora/Cloud/Anthropic/AnthropicProviderFactory.swift` | Create | Factory for LLMProviderManager |
| `OraTests/Cloud/Anthropic/AnthropicProviderTests.swift` | Create | Unit tests with mocked HTTP |

---

## Tests and Validation

### Unit Tests (Mocked HTTP)

- `test_generate_streams_tokens` - Mock SSE stream yields correct LLMDelta tokens
- `test_systemMessage_sentAsSeparateField` - System prompt uses Anthropic's `system` parameter
- `test_toolRole_mappedToUser` - Tool results sent as user messages (Anthropic doesn't have tool role in basic mode)
- `test_401_throwsAuthError` - Authentication failure classified correctly
- `test_429_retriesWithBackoff` - Rate limit triggers retry
- `test_429_maxRetriesExhausted_throws` - Eventually gives up
- `test_500_throwsServerError` - Server errors classified correctly
- `test_messageStop_completesStream` - Clean stream termination
- `test_cancelled_terminatesStream` - Task cancellation stops streaming

### Manual E2E Test

1. Set Anthropic API key via Keychain (or future preferences UI)
2. Switch provider to Anthropic
3. Ask "What's 2+2?" - verify Claude responds
4. Ask "What's on my calendar tomorrow?" - verify tool calling works through existing pipeline
5. Remove API key, verify auth error is surfaced to user

---

## Acceptance Criteria

- [ ] **AC-1:** `AnthropicProvider` conforms to `LLMServicing`
- [ ] **AC-2:** System messages sent via Anthropic's `system` parameter (not in messages array)
- [ ] **AC-3:** SSE stream parsed correctly, yielding `LLMDelta.token` for each text delta
- [ ] **AC-4:** `LLMDelta.completed` emitted with token count from `message_delta` usage
- [ ] **AC-5:** 429 responses trigger exponential backoff retry (max 2 retries)
- [ ] **AC-6:** 401/402 errors surface as `CloudProviderError.authenticationFailed`/`.billingError`
- [ ] **AC-7:** Factory registered with `LLMProviderManager`
- [ ] **AC-8:** Tool calling works through existing `StructuredGenerator` pipeline (no native tool use API)

---

## Risks and Open Questions

| Risk/Question | Notes |
|:--------------|:------|
| Anthropic API versioning | Pin `anthropic-version: 2023-06-01`. Update when needed. |
| Token counting accuracy | `content_block_delta` events don't include token counts. Use `message_delta.usage.output_tokens` for the final count. Per-token count is approximate. |
| Tool role mapping | Anthropic has a `tool` role for native tool use, but since we're using JSON-based tool calling, tool results go as `user` messages. Alternatively, they could be wrapped in the assistant/user turn structure. |
| Model availability | Claude Sonnet 4 is the default. Users with only Haiku access should be able to configure this. |
| Large responses | Anthropic supports up to 128K output. Ora's default 800 tokens is conservative but works. Cloud-specific defaults could be higher. |
| Rate limits | Anthropic has per-model rate limits. The retry logic handles this, but heavy usage may hit limits. |
