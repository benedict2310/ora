//
//  Types.swift
//  Ora
//
//  Shared types for LLM service
//

import Foundation

/// Token generation events
public enum LLMDelta: Sendable {
    case token(String)
    case completed(totalTokens: Int)
}

/// LLM message for conversation
public struct LLMMessage: Sendable, Codable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }
    
    public let role: Role
    public let content: String
    
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// LLM service protocol
public protocol LLMServicing: Sendable {
    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error>
    func warmup() async throws
    func prepare() async throws
    func unload() async
}

/// Errors specific to LLM Service
public enum LLMServiceError: LocalizedError {
    case notReady
    case modelNotFound
    case generationFailed(String)
    case insufficientMemory
    
    public var errorDescription: String? {
        switch self {
        case .notReady:
            return "LLM is not ready. Please wait for model loading."
        case .modelNotFound:
            return "LLM model not found. Please download models first."
        case .generationFailed(let reason):
            return "Generation failed: \(reason)"
        case .insufficientMemory:
            return "Insufficient memory to load the requested model."
        }
    }
}
