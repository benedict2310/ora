//
//  OpenAIProvider.swift
//  Ora
//
//  OpenAI Chat Completions provider implementing LLMServicing
//

import Foundation
import os

/// OpenAI Chat Completions provider implementing LLMServicing
public final class OpenAIProvider: CloudLLMBase, @unchecked Sendable {

    private let model: String
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    // Retry configuration
    private let maxRetries: Int
    private let baseRetryDelay: TimeInterval

    public init(
        apiKey: String,
        model: String = OpenAIModel.preferredDefault.rawValue,
        session: URLSession? = nil,
        maxRetries: Int = 2,
        baseRetryDelay: TimeInterval = 1.0
    ) {
        self.model = model
        self.maxRetries = maxRetries
        self.baseRetryDelay = baseRetryDelay
        super.init(apiKey: apiKey, category: "openai", session: session)
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
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable state in
                if case .cancelled = state {
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Private

    private func streamCompletion(
        messages: [LLMMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        let mappedMessages = messages.map { message in
            [
                "role": message.role == .tool ? "user" : message.role.rawValue,
                "content": message.content,
            ] as [String: Any]
        }

        let body: [String: Any] = [
            "model": self.model,
            "max_completion_tokens": maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": mappedMessages,
        ]

        var request = URLRequest(url: self.baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await self.streamWithRetry(request: request, continuation: continuation)
    }

    private func streamWithRetry(
        request: URLRequest,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        var lastError: Error?

        for attempt in 0...self.maxRetries {
            try Task.checkCancellation()

            if attempt > 0 {
                let delay = self.baseRetryDelay * pow(2.0, Double(attempt - 1))
                self.logger.info("Retrying after \(delay)s (attempt \(attempt + 1))")
                try await Task.sleep(for: .seconds(delay))
            }

            do {
                let (bytes, response) = try await self.session.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CloudProviderError.invalidResponse("Non-HTTP response")
                }

                guard httpResponse.statusCode == 200 else {
                    var errorBody = ""
                    for try await line in bytes.lines {
                        errorBody += line
                    }

                    let error = self.classifyError(
                        statusCode: httpResponse.statusCode,
                        body: errorBody
                    )

                    if case .rateLimited = error, attempt < self.maxRetries {
                        lastError = error
                        continue
                    }
                    throw error
                }

                try await self.parseOpenAISSE(bytes: bytes, continuation: continuation)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as CloudProviderError {
                if case .rateLimited = error, attempt < self.maxRetries {
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

    private func parseOpenAISSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        var tokenCount = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }

            if payload == "[DONE]" {
                continuation.yield(.completed(totalTokens: tokenCount))
                continuation.finish()
                return
            }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let usage = json["usage"] as? [String: Any],
               let completionTokens = usage["completion_tokens"] as? Int {
                tokenCount = completionTokens
            }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw CloudProviderError.requestFailed(statusCode: 0, body: message)
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                continue
            }

            if let delta = choice["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                tokenCount += 1
                continuation.yield(.token(content))
            }
        }

        continuation.yield(.completed(totalTokens: tokenCount))
        continuation.finish()
    }
}
