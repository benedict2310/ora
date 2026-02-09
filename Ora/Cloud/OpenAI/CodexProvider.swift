//
//  CodexProvider.swift
//  Ora
//
//  ChatGPT/Codex OAuth-backed cloud provider.
//

import Foundation

final class CodexProvider: CloudLLMBase, @unchecked Sendable {
    private let model: String
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
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
        _ = maxTokens
        let instructions = self.buildInstructions(from: messages)
        let mappedInput = messages
            .filter { $0.role != .system }
            .map { message in
            [
                "type": "message",
                "role": message.role == .tool ? "user" : message.role.rawValue,
                "content": [
                    [
                        "type": "input_text",
                        "text": message.content,
                    ],
                ],
            ] as [String: Any]
        }

        let body: [String: Any] = [
            "model": self.model,
            "instructions": instructions,
            "input": mappedInput,
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "store": false,
            "stream": true,
        ]

        try await self.streamWithRetry(continuation: continuation) {
            let credential = try await self.credentialProvider()
            var request = URLRequest(url: self.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(credential.accountID, forHTTPHeaderField: "chatgpt-account-id")
            request.setValue(CodexOAuthManager.originator, forHTTPHeaderField: "originator")
            request.setValue(Self.clientVersion, forHTTPHeaderField: "version")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    private func buildInstructions(from messages: [LLMMessage]) -> String {
        let systemMessages = messages
            .filter { $0.role == .system }
            .map(\.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !systemMessages.isEmpty {
            return systemMessages.joined(separator: "\n\n")
        }
        return "You are Ora, a helpful assistant."
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
                    self.logHTTPFailure(
                        statusCode: httpResponse.statusCode,
                        body: errorBody,
                        attemptIndex: attempt
                    )
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
        var lastOutputItemText: String?

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

            if let usageTokens = self.extractUsageTokenCount(from: json) {
                tokenCount = usageTokens
            }

            if let eventType = json["type"] as? String,
               eventType == "response.completed" || eventType == "response.done" {
                continuation.yield(.completed(totalTokens: tokenCount))
                continuation.finish()
                return
            }

            if let text = self.extractTokenText(from: json, lastOutputItemText: &lastOutputItemText) {
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
        if let response = json["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    private func extractUsageTokenCount(from json: [String: Any]) -> Int? {
        if let usage = json["usage"] as? [String: Any],
           let completionTokens = usage["completion_tokens"] as? Int {
            return completionTokens
        }

        if let response = json["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any],
           let outputTokens = usage["output_tokens"] as? Int {
            return outputTokens
        }

        return nil
    }

    private func extractTokenText(from json: [String: Any], lastOutputItemText: inout String?) -> String? {
        if let eventType = json["type"] as? String {
            if eventType == "response.output_text.delta",
               let delta = json["delta"] as? String,
               !delta.isEmpty {
                return delta
            }

            if eventType == "response.output_item.done",
               let item = json["item"] as? [String: Any],
               let content = item["content"] as? [[String: Any]],
               let outputText = content.first(where: { ($0["type"] as? String) == "output_text" })?["text"] as? String,
               !outputText.isEmpty {
                defer { lastOutputItemText = outputText }
                guard let previousText = lastOutputItemText else {
                    return outputText
                }
                if outputText.hasPrefix(previousText) {
                    let suffix = String(outputText.dropFirst(previousText.count))
                    return suffix.isEmpty ? nil : suffix
                }
                return outputText
            }
        }

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

        defer { lastOutputItemText = fullText }
        guard let previous = lastOutputItemText else {
            return fullText
        }

        if fullText.hasPrefix(previous) {
            let suffix = String(fullText.dropFirst(previous.count))
            return suffix.isEmpty ? nil : suffix
        }

        return fullText
    }

    private static var clientVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return version
        }
        return "0.0.0"
    }

    private static var userAgent: String {
        return "\(CodexOAuthManager.originator)/\(Self.clientVersion) (Ora macOS)"
    }

    private func logHTTPFailure(statusCode: Int, body: String, attemptIndex: Int) {
        switch attemptIndex + 1 {
        case 1:
            self.logger.error("CODEX_STREAM_ATTEMPT_1_FAILED")
        case 2:
            self.logger.error("CODEX_STREAM_ATTEMPT_2_FAILED")
        case 3:
            self.logger.error("CODEX_STREAM_ATTEMPT_3_FAILED")
        default:
            self.logger.error("CODEX_STREAM_ATTEMPT_FAILED")
        }

        switch statusCode {
        case 400:
            self.logger.error("CODEX_STREAM_HTTP_400")
        case 401:
            self.logger.error("CODEX_STREAM_HTTP_401")
        case 403:
            self.logger.error("CODEX_STREAM_HTTP_403")
        case 404:
            self.logger.error("CODEX_STREAM_HTTP_404")
        case 408:
            self.logger.error("CODEX_STREAM_HTTP_408")
        case 429:
            self.logger.error("CODEX_STREAM_HTTP_429")
        case 500...599:
            self.logger.error("CODEX_STREAM_HTTP_5XX")
        default:
            self.logger.error("CODEX_STREAM_HTTP_OTHER")
        }

        switch Self.classifyFailureBody(body) {
        case .invalidModel:
            self.logger.error("CODEX_STREAM_HTTP_BODY_INVALID_MODEL")
        case .requestShape:
            self.logger.error("CODEX_STREAM_HTTP_BODY_REQUEST_SHAPE")
        case .tokenParameter:
            self.logger.error("CODEX_STREAM_HTTP_BODY_TOKEN_PARAMETER")
        case .contextLength:
            self.logger.error("CODEX_STREAM_HTTP_BODY_CONTEXT_LENGTH")
        case .unknown:
            self.logger.error("CODEX_STREAM_HTTP_BODY_UNKNOWN")
        }
    }

    private enum FailureBodyCategory {
        case invalidModel
        case requestShape
        case tokenParameter
        case contextLength
        case unknown
    }

    private static func classifyFailureBody(_ body: String) -> FailureBodyCategory {
        let normalized = body.lowercased()
        if normalized.contains("model") &&
            (normalized.contains("not found") ||
                normalized.contains("does not exist") ||
                normalized.contains("invalid model") ||
                normalized.contains("unsupported")) {
            return .invalidModel
        }
        if normalized.contains("max_tokens") ||
            normalized.contains("max_output_tokens") ||
            normalized.contains("max_completion_tokens") {
            return .tokenParameter
        }
        if normalized.contains("context length") ||
            normalized.contains("maximum context") ||
            normalized.contains("too many tokens") {
            return .contextLength
        }
        if normalized.contains("invalid_request_error") ||
            normalized.contains("invalid value") ||
            normalized.contains("unsupported value") ||
            normalized.contains("invalid type") ||
            normalized.contains("validation") ||
            normalized.contains("\"role\"") ||
            normalized.contains("messages") ||
            normalized.contains("input") ||
            normalized.contains("tool_choice") {
            return .requestShape
        }
        return .unknown
    }
}
