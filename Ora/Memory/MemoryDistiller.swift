//
//  MemoryDistiller.swift
//  Ora
//
//  Distills completed session transcripts into a structured summary
//  and append-only long-term memory entries.
//

import Foundation
import MLX
import os

protocol MemoryDistilling: Sendable {
    func distill(sessionId: UUID) async -> SessionSummary?
}

actor MemoryDistiller: MemoryDistilling {

    // MARK: - Types

    typealias TranscriptLoader = @Sendable (UUID) async -> [Session.Message]?
    typealias PromptLoader = @Sendable () -> String

    // MARK: - Singleton

    static let shared = MemoryDistiller()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "memory")
    private let llm: LLMServicing
    private let memoryFileManager: MemoryFileManager
    private let transcriptLoader: TranscriptLoader
    private let promptLoader: PromptLoader
    private let maxRetries: Int
    private let maxTokens: Int

    // MARK: - Initialization

    init(
        llm: LLMServicing = LLMService.shared,
        memoryFileManager: MemoryFileManager = MemoryFileManager(),
        transcriptLoader: @escaping TranscriptLoader = MemoryDistiller.defaultTranscriptLoader,
        promptLoader: @escaping PromptLoader = MemoryDistiller.loadPrompt,
        maxRetries: Int = 3,
        maxTokens: Int = 1200
    ) {
        self.llm = llm
        self.memoryFileManager = memoryFileManager
        self.transcriptLoader = transcriptLoader
        self.promptLoader = promptLoader
        self.maxRetries = maxRetries
        self.maxTokens = maxTokens
    }

    // MARK: - Public API

    func distill(sessionId: UUID) async -> SessionSummary? {
        defer {
            GPU.clearCache()
        }

        guard let messages = await self.transcriptLoader(sessionId) else {
            self.logger.warning("Memory distillation skipped: no persisted session found for \(sessionId.uuidString)")
            return nil
        }

        let transcript = self.renderTranscript(messages)

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let emptySummary = SessionSummary()
            do {
                try self.memoryFileManager.writeSummary(sessionId: sessionId, content: emptySummary.renderMarkdown())
            } catch {
                self.logger.error("Failed to write empty session summary for \(sessionId.uuidString): \(error.localizedDescription)")
            }
            return emptySummary
        }

        do {
            try await self.llm.prepare()

            let prompt = self.promptLoader()
            let payload = try await self.generatePayload(prompt: prompt, transcript: transcript)

            let summaryMarkdown = payload.summary.renderMarkdown()
            try self.memoryFileManager.writeSummary(sessionId: sessionId, content: summaryMarkdown)
            try self.memoryFileManager.appendToMemory(entries: payload.memoryEntries, sessionId: sessionId)

            self.logger.info("Memory distillation completed for session \(sessionId.uuidString)")
            return payload.summary
        } catch {
            self.logger.warning("Memory distillation failed for session \(sessionId.uuidString): \(error.localizedDescription)")

            do {
                try self.memoryFileManager.writeSummary(sessionId: sessionId, content: SessionSummary.placeholder.renderMarkdown())
            } catch {
                self.logger.error("Failed to write placeholder summary for session \(sessionId.uuidString): \(error.localizedDescription)")
            }

            return SessionSummary.placeholder
        }
    }

    // MARK: - Payload Generation

    private func generatePayload(prompt: String, transcript: String) async throws -> DistillationPayload {
        let baseMessages = [
            LLMMessage(role: .system, content: prompt),
            LLMMessage(role: .user, content: "Transcript:\n\n\(transcript)")
        ]

        var messages = baseMessages
        var lastParsingError: Error?

        for attempt in 1...self.maxRetries {
            let response = try await self.generateResponse(messages: messages)

            do {
                return try Self.parsePayload(from: response)
            } catch {
                lastParsingError = error
                self.logger.warning("Memory distillation parse failed on attempt \(attempt): \(error.localizedDescription)")

                if attempt < self.maxRetries {
                    let retryMessage = Self.retryPrompt(for: response)
                    messages = baseMessages + [LLMMessage(role: .user, content: retryMessage)]
                }
            }
        }

        throw MemoryDistillerError.invalidModelOutput(lastParsingError?.localizedDescription ?? "Unknown parsing error")
    }

    private func generateResponse(messages: [LLMMessage]) async throws -> String {
        var fullResponse = ""

        for try await delta in await self.llm.generate(messages: messages, maxTokens: self.maxTokens) {
            if case .token(let text) = delta {
                fullResponse += text
            }
        }

        return fullResponse
    }

    // MARK: - Transcript Rendering

    private func renderTranscript(_ messages: [Session.Message]) -> String {
        guard !messages.isEmpty else {
            return ""
        }

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        return messages.map { message in
            let timestamp = timestampFormatter.string(from: message.timestamp)
            let role = message.role.rawValue.uppercased()
            let content = message.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(timestamp)] \(role): \(content)"
        }.joined(separator: "\n")
    }

    // MARK: - Prompt Loading

    private static func loadPrompt() -> String {
        guard let url = Bundle.main.url(forResource: "memory-distill-prompt", withExtension: "txt") else {
            return Self.fallbackPrompt
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return Self.fallbackPrompt
        }

        return content
    }

    private static let fallbackPrompt = """
You distill a conversation transcript into JSON.

Return ONLY one JSON object in this exact shape:
{
  "summary": {
    "tldr": "string",
    "bullets": ["string"],
    "decisions_and_commitments": [
      {
        "decision": "string",
        "rationale": "string",
        "timestamp": "ISO-8601 timestamp"
      }
    ],
    "open_loops": ["string"]
  },
  "memory_entries": ["string"]
}

Rules:
- Include only durable facts/preferences/decisions.
- If unknown, return empty arrays and empty strings.
- No markdown, no prose, no code fences.
"""

    // MARK: - Persistence Loading

    private static func defaultTranscriptLoader(sessionId: UUID) async -> [Session.Message]? {
        return await MainActor.run {
            return PersistenceManager.shared.messageSnapshot(sessionId: sessionId)
        }
    }

    // MARK: - Parsing

    private static func parsePayload(from response: String) throws -> DistillationPayload {
        let cleaned = Self.cleanResponse(response)

        if let payload = try Self.decodePayload(candidate: cleaned) {
            return payload
        }

        for candidate in Self.extractJSONObjectCandidates(from: cleaned) {
            if let payload = try Self.decodePayload(candidate: candidate) {
                return payload
            }
        }

        throw MemoryDistillerError.invalidModelOutput("Unable to decode distillation JSON")
    }

    private static func cleanResponse(_ response: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }

        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodePayload(candidate: String) throws -> DistillationPayload? {
        guard let data = candidate.data(using: .utf8) else {
            return nil
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let json = object as? [String: Any] else {
                return nil
            }

            let normalizedData = try JSONSerialization.data(withJSONObject: json, options: [])
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(DistillationEnvelope.self, from: normalizedData)
            return envelope.toPayload()
        } catch {
            throw error
        }
    }

    private static func extractJSONObjectCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var isInString = false
        var isEscaping = false
        var startIndex: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if isEscaping {
                isEscaping = false
                index = text.index(after: index)
                continue
            }

            if character == "\\" {
                if isInString {
                    isEscaping = true
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                isInString.toggle()
                index = text.index(after: index)
                continue
            }

            if isInString {
                index = text.index(after: index)
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let start = startIndex {
                        candidates.append(String(text[start...index]))
                        startIndex = nil
                        if candidates.count >= 8 {
                            break
                        }
                    }
                }
            }

            index = text.index(after: index)
        }

        return candidates
    }

    private static func retryPrompt(for invalidResponse: String) -> String {
        let trimmed = invalidResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet: String
        if trimmed.count > 1200 {
            snippet = String(trimmed.prefix(1200))
        } else {
            snippet = trimmed
        }

        return """
Your previous output did not match the required JSON schema.
Respond again with ONLY one valid JSON object that matches the exact shape.
Do not include markdown or any surrounding text.

Previous invalid output:
\(snippet)
"""
    }
}

// MARK: - Distillation Payload

private struct DistillationPayload: Sendable {
    let summary: SessionSummary
    let memoryEntries: [String]
}

private struct DistillationEnvelope: Decodable {

    let summary: DistilledSummary
    let memoryEntries: [String]

    enum CodingKeys: String, CodingKey {
        case summary
        case memoryEntries = "memory_entries"
    }

    func toPayload() -> DistillationPayload {
        let summary = SessionSummary(
            tldr: self.summary.tldr.trimmingCharacters(in: .whitespacesAndNewlines),
            bullets: self.summary.bullets
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            decisionsAndCommitments: self.summary.decisionsAndCommitments
                .filter { !$0.decision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { decision in
                    SessionSummary.DecisionCommitment(
                        decision: decision.decision.trimmingCharacters(in: .whitespacesAndNewlines),
                        rationale: decision.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                        timestamp: decision.resolvedTimestamp
                    )
                },
            openLoops: self.summary.openLoops
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        let normalizedMemoryEntries = self.memoryEntries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return DistillationPayload(summary: summary, memoryEntries: normalizedMemoryEntries)
    }
}

private struct DistilledSummary: Decodable {
    let tldr: String
    let bullets: [String]
    let decisionsAndCommitments: [DistilledDecision]
    let openLoops: [String]

    enum CodingKeys: String, CodingKey {
        case tldr
        case bullets
        case decisionsAndCommitments = "decisions_and_commitments"
        case openLoops = "open_loops"
    }
}

private struct DistilledDecision: Decodable {
    let decision: String
    let rationale: String
    let timestamp: String?

    var resolvedTimestamp: Date {
        guard let timestamp else {
            return Date()
        }

        if let date = Self.parseISO8601WithFractional(timestamp) {
            return date
        }

        if let date = Self.parseISO8601(timestamp) {
            return date
        }

        return Date()
    }

    private static func parseISO8601WithFractional(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp)
    }

    private static func parseISO8601(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

enum MemoryDistillerError: LocalizedError {
    case invalidModelOutput(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelOutput(let reason):
            return "Memory distillation output was invalid: \(reason)"
        }
    }
}
