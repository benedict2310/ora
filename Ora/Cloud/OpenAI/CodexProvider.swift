//
//  CodexProvider.swift
//  Ora
//
//  ChatGPT/Codex OAuth-backed cloud provider.
//

import Foundation

final class CodexProvider: CloudLLMBase, @unchecked Sendable {
    private let model: String
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/conversation")!
    private let credentialProvider: @Sendable () async throws -> CodexOAuthCredential
    private let maxRetries: Int
    private let baseRetryDelay: TimeInterval

    init(
        model: String = OpenAIModel.gpt4o.rawValue,
        credentialProvider: @escaping @Sendable () async throws -> CodexOAuthCredential,
        session: URLSession? = nil,
        maxRetries: Int = 2,
        baseRetryDelay: TimeInterval = 1.0
    ) {
        self.model = model
        self.credentialProvider = credentialProvider
        self.maxRetries = maxRetries
        self.baseRetryDelay = baseRetryDelay
        super.init(apiKey: "<oauth>", category: "codex-provider", session: session)
    }

    override func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
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
            "messages": mappedMessages,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        try await self.streamWithRetry(continuation: continuation) {
            let credential = try await self.credentialProvider()
            var request = URLRequest(url: self.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(credential.accountID, forHTTPHeaderField: "chatgpt-account-id")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    private func streamWithRetry(
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation,
        buildRequest: @escaping () async throws -> URLRequest
    ) async throws {
        var lastError: Error?

        for attempt in 0...self.maxRetries {
            try Task.checkCancellation()

            if attempt > 0 {
                let delay = self.baseRetryDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(for: .seconds(delay))
            }

            do {
                let request = try await buildRequest()
                let (bytes, response) = try await self.session.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CloudProviderError.invalidResponse("Non-HTTP response")
                }

                guard httpResponse.statusCode == 200 else {
                    var errorBody = ""
                    for try await line in bytes.lines {
                        errorBody += line
                    }
                    let error = self.classifyError(statusCode: httpResponse.statusCode, body: errorBody)
                    if case .rateLimited = error, attempt < self.maxRetries {
                        lastError = error
                        continue
                    }
                    throw error
                }

                try await self.parseCodexSSE(bytes: bytes, continuation: continuation)
                return
            } catch is CancellationError {
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

    private func parseCodexSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        var tokenCount = 0
        var lastFullMessage: String?

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

            if let error = self.errorMessage(from: json) {
                throw CloudProviderError.requestFailed(statusCode: 0, body: error)
            }

            if let usage = json["usage"] as? [String: Any],
               let completionTokens = usage["completion_tokens"] as? Int {
                tokenCount = completionTokens
            }

            if let text = self.extractTokenText(from: json, lastFullMessage: &lastFullMessage) {
                tokenCount += 1
                continuation.yield(.token(text))
            }
        }

        continuation.yield(.completed(totalTokens: tokenCount))
        continuation.finish()
    }

    private func errorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? String {
            return error
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    private func extractTokenText(from json: [String: Any], lastFullMessage: inout String?) -> String? {
        if let delta = json["delta"] as? String, !delta.isEmpty {
            return delta
        }

        if let text = json["text"] as? String, !text.isEmpty {
            return text
        }

        if let choices = json["choices"] as? [[String: Any]],
           let choice = choices.first,
           let delta = choice["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            return content
        }

        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [String: Any],
              let parts = content["parts"] as? [String],
              let fullText = parts.first,
              !fullText.isEmpty else {
            return nil
        }

        defer { lastFullMessage = fullText }
        guard let previous = lastFullMessage else {
            return fullText
        }

        if fullText.hasPrefix(previous) {
            let suffix = String(fullText.dropFirst(previous.count))
            return suffix.isEmpty ? nil : suffix
        }

        return fullText
    }
}
