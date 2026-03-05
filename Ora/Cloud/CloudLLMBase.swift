//
//  CloudLLMBase.swift
//  Ora
//
//  Base class for cloud LLM providers implementing LLMServicing
//

import Foundation
import os

/// Base class for cloud LLM providers implementing LLMServicing
///
/// Handles common concerns:
/// - SSE (Server-Sent Events) stream parsing
/// - HTTP error classification (auth, rate limit, billing)
/// - Request/response logging
open class CloudLLMBase: LLMServicing, @unchecked Sendable {

    public let logger: Logger
    public let apiKey: String
    public let session: URLSession

    public init(apiKey: String, category: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.logger = Logger.ora(category: category)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - LLMServicing Protocol

    // Subclasses MUST override generate
    open func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        fatalError("Subclasses must override generate(messages:maxTokens:)")
    }

    open func warmup() async throws {
        // No-op: cloud providers don't need warmup
    }

    open func prepare() async throws {
        // Subclasses can override to validate API key
    }

    open func unload() async {
        // No-op: nothing to unload
    }

    open func capabilities() async -> ProviderCapabilities {
        return .textOnly
    }

    open func clearCache() async {
        // No-op: no local KV cache
    }

    public func assertTextOnlyInput(messages: [LLMMessage], providerName: String) throws {
        guard messages.contains(where: \.containsImageAttachments) else {
            return
        }

        throw CloudProviderError.unsupportedInput(
            "\(providerName) currently supports text-only input in Ora. Remove image attachments and try again."
        )
    }

    // MARK: - SSE Parsing

    /// Parse an SSE stream from URLSession bytes
    /// Yields the data payload (after "data: ")
    public func parseSSEStream(
        _ bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        // Skip empty lines or keep-alives
                        guard !line.isEmpty else { continue }
                        
                        if line.hasPrefix("data: ") {
                            let data = String(line.dropFirst(6))
                            if data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                                continuation.finish()
                                return
                            }
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Error Classification

    /// Classify an HTTP error response
    public func classifyError(statusCode: Int, body: String) -> CloudProviderError {
        switch statusCode {
        case 401: return .authenticationFailed(body)
        case 402: return .billingError(body)
        case 429: return .rateLimited(retryAfter: parseRetryAfter(body)) // TODO: Parse actual header if available, body fallback
        case 500...599: return .serverError(statusCode: statusCode, body: body)
        default: return .requestFailed(statusCode: statusCode, body: body)
        }
    }
    
    private func parseRetryAfter(_ body: String) -> TimeInterval? {
        // Simplistic body parsing, ideally we'd pass headers here too
        // For now, return nil (exponential backoff handled by caller if needed)
        return nil
    }
}
