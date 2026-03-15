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

public struct LLMImageAttachmentReference: Sendable, Codable, Equatable {
    public let attachmentID: UUID
    public let stagedFilePath: String
    public let mimeType: String
    public let byteCount: Int?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        attachmentID: UUID = UUID(),
        stagedFilePath: String,
        mimeType: String,
        byteCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.attachmentID = attachmentID
        self.stagedFilePath = stagedFilePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum LLMMessageContentPart: Sendable, Codable, Equatable {
    case text(String)
    case image(LLMImageAttachmentReference)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image
    }

    private enum PartType: String, Codable {
        case text
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PartType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(try container.decode(LLMImageAttachmentReference.self, forKey: .image))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let value):
            try container.encode(PartType.image, forKey: .type)
            try container.encode(value, forKey: .image)
        }
    }

    public var textValue: String? {
        guard case .text(let value) = self else {
            return nil
        }
        return value
    }
}

/// LLM message for conversation
public struct LLMMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case contentParts
    }

    public let role: Role
    public let contentParts: [LLMMessageContentPart]

    public init(role: Role, content: String) {
        self.role = role
        self.contentParts = [.text(content)]
    }

    public init(role: Role, contentParts: [LLMMessageContentPart]) {
        self.role = role
        self.contentParts = contentParts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(Role.self, forKey: .role)

        if let parts = try container.decodeIfPresent([LLMMessageContentPart].self, forKey: .contentParts) {
            self.contentParts = parts
            return
        }

        if container.contains(.content) {
            if let text = try? container.decode(String.self, forKey: .content) {
                self.contentParts = [.text(text)]
                return
            }

            if let parts = try? container.decode([LLMMessageContentPart].self, forKey: .content) {
                self.contentParts = parts
                return
            }
        }

        self.contentParts = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.role, forKey: .role)

        if self.contentParts.count == 1, case .text(let text) = self.contentParts[0] {
            try container.encode(text, forKey: .content)
        } else {
            try container.encode(self.contentParts, forKey: .contentParts)
        }
    }

    public var content: String {
        return self.textContent
    }

    public var textContent: String {
        return self.contentParts.compactMap(\.textValue).joined()
    }

    public var containsImageAttachments: Bool {
        return self.contentParts.contains { part in
            if case .image = part {
                return true
            }
            return false
        }
    }

    public var imageAttachments: [LLMImageAttachmentReference] {
        return self.contentParts.compactMap { part in
            guard case .image(let image) = part else {
                return nil
            }
            return image
        }
    }
}

/// LLM service protocol
public protocol LLMServicing: Sendable {
    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error>
    func warmup() async throws
    func prepare() async throws
    func unload() async
    func capabilities() async -> ProviderCapabilities
    
    /// Clear the KV cache to free memory and start fresh for a new session
    func clearCache() async

    /// Generate a one-shot completion with an isolated KV cache.
    ///
    /// Unlike `generate(messages:maxTokens:)`, this method creates a fresh KV cache,
    /// runs generation, and discards the cache afterward. This prevents background
    /// summarization from corrupting the foreground conversation's persistent cache.
    func generateOneShot(prompt: String, maxTokens: Int) async throws -> String
}

// Default implementation for conformers that don't need one-shot generation.
// Falls back to using the standard generate method with a single user message.
extension LLMServicing {
    func generateOneShot(prompt: String, maxTokens: Int = 800) async throws -> String {
        let messages = [LLMMessage(role: .user, content: prompt)]
        let stream = await self.generate(messages: messages, maxTokens: maxTokens)
        var result = ""
        for try await delta in stream {
            if case .token(let token) = delta {
                result += token
            }
        }
        return result
    }
}

/// Errors specific to LLM Service
public enum LLMServiceError: LocalizedError {
    case notReady
    case modelNotFound
    case generationFailed(String)
    case insufficientMemory
    case unsupportedInput(String)
    
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
        case .unsupportedInput(let reason):
            return reason
        }
    }
}
