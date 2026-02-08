//
//  AnthropicProvider.swift
//  Ora
//
//  Anthropic Claude provider implementing LLMServicing
//

import Foundation
import os

/// Anthropic Claude provider implementing LLMServicing
public final class AnthropicProvider: CloudLLMBase, @unchecked Sendable {

    private let model: String
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    // Retry configuration
    private let maxRetries = 2
    private let baseRetryDelay: TimeInterval = 1.0

    public init(apiKey: String, model: String = AnthropicModel.sonnet.rawValue) {
        self.model = model
        super.init(apiKey: apiKey, category: "anthropic")
    }

    // MARK: - LLMServicing

    public override func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
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
                    for try await line in bytes.lines {
                        errorBody += line
                    }

                    let error = classifyError(
                        statusCode: httpResponse.statusCode,
                        body: errorBody
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
}
