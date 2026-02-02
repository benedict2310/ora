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
        
        while attempts < maxRetries {
            attempts += 1
            var responseParser = ResponseTextStreamParser()
            
            // Collect full response
            var fullResponse = ""
            for try await delta in await llm.generate(messages: currentMessages, maxTokens: 800) {
                if case .token(let text) = delta {
                    fullResponse += text
                    if let handler = responseTokenHandler {
                        let fragments = responseParser.append(text)
                        for fragment in fragments where !fragment.isEmpty {
                            await handler(fragment)
                        }
                    }
                }
            }
            
            // Log raw LLM output for debugging
            // NOTE: privacy: .public is temporary for debugging — remove before shipping
            let truncated = String(fullResponse.prefix(300))
            logger.info("LLM raw output (attempt \(attempts, privacy: .public), \(fullResponse.count, privacy: .public) chars): \(truncated, privacy: .public)")

            // Validate JSON
            let result = JSONValidator.parse(fullResponse)

            switch result {
            case .success(let output):
                logger.info("Parsed LLM output: type=\(output.typeLabel, privacy: .public) attempt=\(attempts, privacy: .public)")
                return output

            case .failure(let error):
                lastError = error
                logger.warning("Validation failed (attempt \(attempts)): \(error.localizedDescription)")
                
                // Add retry message
                if attempts < maxRetries {
                    currentMessages = messages + [
                        LLMMessage(role: .assistant, content: fullResponse),
                        LLMMessage(role: .user, content: retryPrompt ?? Self.defaultRetryPrompt)
                    ]
                }
            }
        }
        
        // All retries exhausted
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
