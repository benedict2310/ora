//
//  StructuredGenerator.swift
//  Ora
//
//  Generates structured output with retry logic
//

import Foundation
import os

/// Generates validated structured output from LLM
actor StructuredGenerator {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "StructuredGenerator")
    private let maxRetries = 3
    private let llm: LLMServicing
    private let retryResponseSnippetLimit = 1200
    
    // MARK: - Initialization
    
    init(llm: LLMServicing = LLMService.shared) {
        self.llm = llm
    }
    
    // MARK: - Public API
    
    /// Generate structured output with validation and retry
    func generate(
        messages: [LLMMessage],
        retryPrompt: String? = nil,
        responseTokenHandler: (@Sendable (String) async -> Void)? = nil
    ) async throws -> LLMOutput {
        var attempts = 0
        var lastError: Error?
        var currentMessages = messages
        self.logger.notice("STRUCTURED_GENERATION_STARTED")
        
        while attempts < maxRetries {
            attempts += 1
            var responseParser = ResponseTextStreamParser()
            self.logAttemptStarted(attempts)
            
            // Collect full response
            var fullResponse = ""
            var pendingFragments: [String] = []
            do {
                for try await delta in await llm.generate(messages: currentMessages, maxTokens: 800) {
                    if case .token(let text) = delta {
                        fullResponse += text
                        let fragments = responseParser.append(text)
                        for fragment in fragments where !fragment.isEmpty {
                            pendingFragments.append(fragment)
                        }
                    }
                }
            } catch {
                lastError = error
                self.logAttemptStreamFailed(attempts, error: error)
                if attempts < maxRetries {
                    // Reset to original base messages after transport/request failure.
                    currentMessages = messages
                    continue
                }
                throw error
            }

            self.logAttemptCompleted(attempts, emittedFragments: !pendingFragments.isEmpty)

            // Validate JSON
            let result = JSONValidator.parse(fullResponse)

            switch result {
            case .success(let output):
                self.logAttemptSucceeded(attempts, outputType: output.typeLabel)
                if let handler = responseTokenHandler {
                    for fragment in pendingFragments where !fragment.isEmpty {
                        await handler(fragment)
                    }
                }
                return output

            case .failure(let error):
                lastError = error
                self.logAttemptValidationFailed(attempts, error: error, rawOutput: fullResponse)
                
                // Add retry message
                if attempts < maxRetries {
                    currentMessages = self.makeRetryMessages(
                        baseMessages: messages,
                        invalidResponse: fullResponse,
                        retryPrompt: retryPrompt
                    )
                }
            }
        }
        
        // All retries exhausted
        self.logger.error("STRUCTURED_GENERATION_EXHAUSTED_RETRIES")
        throw StructuredGeneratorError.validationFailed(
            attempts: attempts,
            lastError: lastError?.localizedDescription ?? "Unknown error"
        )
    }
    
    // MARK: - Private
    
    private static let defaultRetryPrompt = """
        Your previous response was not valid JSON. You MUST respond with ONLY a JSON object.
        Do not include any text before or after the JSON.
        Do not use markdown code blocks.
        Just output the raw JSON object starting with { and ending with }.
        """

    private func makeRetryMessages(
        baseMessages: [LLMMessage],
        invalidResponse: String,
        retryPrompt: String?
    ) -> [LLMMessage] {
        let prompt = retryPrompt ?? Self.defaultRetryPrompt
        let trimmedResponse = invalidResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            return baseMessages + [LLMMessage(role: .user, content: prompt)]
        }

        let snippet: String
        if trimmedResponse.count > self.retryResponseSnippetLimit {
            snippet = String(trimmedResponse.prefix(self.retryResponseSnippetLimit))
        } else {
            snippet = trimmedResponse
        }

        let retryMessage = """
            \(prompt)

            Previous invalid response (for correction context):
            \(snippet)
            """

        return baseMessages + [LLMMessage(role: .user, content: retryMessage)]
    }

    private func logAttemptStarted(_ attempt: Int) {
        switch attempt {
        case 1:
            self.logger.notice("STRUCTURED_ATTEMPT_1_STARTED")
        case 2:
            self.logger.notice("STRUCTURED_ATTEMPT_2_STARTED")
        case 3:
            self.logger.notice("STRUCTURED_ATTEMPT_3_STARTED")
        default:
            self.logger.notice("STRUCTURED_ATTEMPT_STARTED")
        }
    }

    private func logAttemptCompleted(_ attempt: Int, emittedFragments: Bool) {
        switch (attempt, emittedFragments) {
        case (1, true):
            self.logger.notice("STRUCTURED_ATTEMPT_1_COMPLETED_WITH_FRAGMENTS")
        case (2, true):
            self.logger.notice("STRUCTURED_ATTEMPT_2_COMPLETED_WITH_FRAGMENTS")
        case (3, true):
            self.logger.notice("STRUCTURED_ATTEMPT_3_COMPLETED_WITH_FRAGMENTS")
        case (1, false):
            self.logger.notice("STRUCTURED_ATTEMPT_1_COMPLETED_NO_FRAGMENTS")
        case (2, false):
            self.logger.notice("STRUCTURED_ATTEMPT_2_COMPLETED_NO_FRAGMENTS")
        case (3, false):
            self.logger.notice("STRUCTURED_ATTEMPT_3_COMPLETED_NO_FRAGMENTS")
        default:
            self.logger.notice("STRUCTURED_ATTEMPT_COMPLETED")
        }
    }

    private func logAttemptSucceeded(_ attempt: Int, outputType: String) {
        self.logger.info("STRUCTURED_ATTEMPT_SUCCEEDED outputType=\(outputType)")
        switch attempt {
        case 1:
            self.logger.notice("STRUCTURED_ATTEMPT_1_SUCCEEDED")
        case 2:
            self.logger.notice("STRUCTURED_ATTEMPT_2_SUCCEEDED")
        case 3:
            self.logger.notice("STRUCTURED_ATTEMPT_3_SUCCEEDED")
        default:
            self.logger.notice("STRUCTURED_ATTEMPT_SUCCEEDED")
        }
    }

    private func logAttemptValidationFailed(_ attempt: Int, error: Error, rawOutput: String) {
        self.logger.warning("STRUCTURED_ATTEMPT_VALIDATION_FAILED reason=\(error.localizedDescription)")
        switch attempt {
        case 1:
            self.logger.notice("STRUCTURED_ATTEMPT_1_VALIDATION_FAILED")
        case 2:
            self.logger.notice("STRUCTURED_ATTEMPT_2_VALIDATION_FAILED")
        case 3:
            self.logger.notice("STRUCTURED_ATTEMPT_3_VALIDATION_FAILED")
        default:
            self.logger.notice("STRUCTURED_ATTEMPT_VALIDATION_FAILED")
        }

        self.logValidationFailureCategory(error)
        self.logValidationOutputShape(rawOutput)
    }

    private func logAttemptStreamFailed(_ attempt: Int, error: Error) {
        switch attempt {
        case 1:
            self.logger.error("STRUCTURED_ATTEMPT_1_STREAM_FAILED")
        case 2:
            self.logger.error("STRUCTURED_ATTEMPT_2_STREAM_FAILED")
        case 3:
            self.logger.error("STRUCTURED_ATTEMPT_3_STREAM_FAILED")
        default:
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED")
        }

        guard let cloudError = error as? CloudProviderError else {
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_NON_CLOUD_ERROR")
            return
        }

        switch cloudError {
        case .authenticationFailed:
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_AUTHENTICATION")
        case .billingError:
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_BILLING")
        case .rateLimited:
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_RATE_LIMITED")
        case .serverError:
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_SERVER")
        case .connectionFailed:
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_CONNECTION")
        case .invalidResponse:
            self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_INVALID_RESPONSE")
        case .requestFailed(let statusCode, let body):
            switch statusCode {
            case 400:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_400")
            case 401:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_401")
            case 403:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_403")
            case 404:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_404")
            case 408:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_408")
            case 429:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_429")
            case 500...599:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_5XX")
            default:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_REQUEST_OTHER")
            }

            switch Self.classifyCloudRequestBody(body) {
            case .invalidModel:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_BODY_INVALID_MODEL")
            case .requestShape:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_BODY_REQUEST_SHAPE")
            case .tokens:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_BODY_TOKEN_PARAMETER")
            case .contextLength:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_BODY_CONTEXT_LENGTH")
            case .unknown:
                self.logger.error("STRUCTURED_ATTEMPT_STREAM_FAILED_CLOUD_BODY_UNKNOWN")
            }
        }
    }

    private enum CloudRequestBodyCategory {
        case invalidModel
        case requestShape
        case tokens
        case contextLength
        case unknown
    }

    private static func classifyCloudRequestBody(_ body: String) -> CloudRequestBodyCategory {
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
            return .tokens
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

    private func logValidationFailureCategory(_ error: Error) {
        guard let validationError = error as? JSONValidationError else {
            self.logger.error("STRUCTURED_ATTEMPT_VALIDATION_FAILURE_UNKNOWN_TYPE")
            return
        }

        switch validationError {
        case .invalidEncoding:
            self.logger.error("STRUCTURED_ATTEMPT_VALIDATION_FAILURE_INVALID_ENCODING")
        case .invalidJSON:
            self.logger.error("STRUCTURED_ATTEMPT_VALIDATION_FAILURE_INVALID_JSON")
        case .notAnObject:
            self.logger.error("STRUCTURED_ATTEMPT_VALIDATION_FAILURE_NOT_OBJECT")
        case .missingField:
            self.logger.error("STRUCTURED_ATTEMPT_VALIDATION_FAILURE_MISSING_FIELD")
        case .unknownType:
            self.logger.error("STRUCTURED_ATTEMPT_VALIDATION_FAILURE_UNKNOWN_TYPE_FIELD")
        }
    }

    private func logValidationOutputShape(_ rawOutput: String) {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.logger.error("STRUCTURED_ATTEMPT_VALIDATION_OUTPUT_EMPTY")
            return
        }

        if trimmed.hasPrefix("{") {
            self.logger.notice("STRUCTURED_ATTEMPT_VALIDATION_OUTPUT_STARTS_WITH_OBJECT")
        } else {
            self.logger.notice("STRUCTURED_ATTEMPT_VALIDATION_OUTPUT_NOT_OBJECT_PREFIX")
        }

        if trimmed.contains("```") {
            self.logger.notice("STRUCTURED_ATTEMPT_VALIDATION_OUTPUT_CONTAINS_CODE_FENCE")
        }

        if trimmed.lowercased().contains("\"type\"") {
            self.logger.notice("STRUCTURED_ATTEMPT_VALIDATION_OUTPUT_CONTAINS_TYPE_FIELD")
        }

        if trimmed.lowercased().contains("\"tool\"") || trimmed.lowercased().contains("\"name\"") {
            self.logger.notice("STRUCTURED_ATTEMPT_VALIDATION_OUTPUT_CONTAINS_TOOL_FIELD")
        }
    }
}

// MARK: - Errors

enum StructuredGeneratorError: LocalizedError {
    case validationFailed(attempts: Int, lastError: String)
    
    var errorDescription: String? {
        switch self {
        case .validationFailed(let attempts, let lastError):
            return "Failed to generate valid JSON after \(attempts) attempts. Last error: \(lastError)"
        }
    }
}
