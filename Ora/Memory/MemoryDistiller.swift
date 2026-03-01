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

    private let logger = Logger.ora(category: "memory")
    private let llm: LLMServicing
    private let memoryFileManager: MemoryFileManager
    private let memoryIndex: any MemoryIndexing
    private let transcriptLoader: TranscriptLoader
    private let promptLoader: PromptLoader
    private let maxRetries: Int
    private let maxTokens: Int
    private let minimumUserMessageCount: Int
    private let minimumUserCharacterCount: Int
    private let existingMemoryContextCharacterLimit: Int

    // MARK: - Initialization

    init(
        llm: LLMServicing = LLMService.shared,
        memoryFileManager: MemoryFileManager = MemoryFileManager(),
        memoryIndex: any MemoryIndexing = MemoryIndex.shared,
        transcriptLoader: @escaping TranscriptLoader = MemoryDistiller.defaultTranscriptLoader,
        promptLoader: @escaping PromptLoader = MemoryDistiller.loadPrompt,
        maxRetries: Int = 3,
        maxTokens: Int = 1200,
        minimumUserMessageCount: Int = 3,
        minimumUserCharacterCount: Int = 50,
        existingMemoryContextCharacterLimit: Int = 2_000
    ) {
        self.llm = llm
        self.memoryFileManager = memoryFileManager
        self.memoryIndex = memoryIndex
        self.transcriptLoader = transcriptLoader
        self.promptLoader = promptLoader
        self.maxRetries = maxRetries
        self.maxTokens = maxTokens
        self.minimumUserMessageCount = minimumUserMessageCount
        self.minimumUserCharacterCount = minimumUserCharacterCount
        self.existingMemoryContextCharacterLimit = existingMemoryContextCharacterLimit
    }

    // MARK: - Public API

    func distill(sessionId: UUID) async -> SessionSummary? {
        guard let messages = await self.transcriptLoader(sessionId) else {
            self.logger.warning("Memory distillation skipped: no persisted session found for \(sessionId.uuidString)")
            return nil
        }

        if self.shouldSkipMemoryDistillation(for: messages) {
            self.logger.info("Memory distillation skipped: session \(sessionId.uuidString) below threshold")
            return nil
        }

        let transcript = self.renderTranscript(messages)

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.logger.info("Memory distillation skipped: session \(sessionId.uuidString) has empty transcript")
            return nil
        }

        do {
            try await self.llm.prepare()
            // Only clear GPU cache after the model has been prepared.
            // Calling GPU.clearCache() on an uninitialized MLX Metal context
            // causes an async GPU crash that can be attributed to any running test.
            defer {
                GPU.clearCache()
            }

            let prompt = self.promptLoader()
            let distillationTimestamp = Date()
            let existingMemoryContext = self.loadExistingMemoryContext(limit: self.existingMemoryContextCharacterLimit)
            let payload = try await self.generatePayload(
                prompt: prompt,
                transcript: transcript,
                existingMemoryContext: existingMemoryContext,
                sessionId: sessionId,
                timestamp: distillationTimestamp
            )

            let summaryMarkdown = payload.summary.renderMarkdown()
            try self.memoryFileManager.writeSummary(sessionId: sessionId, content: summaryMarkdown)
            try self.memoryFileManager.appendEntries(entries: payload.memoryEntries)
            await self.memoryIndex.rebuild()

            self.logger.info("Memory distillation completed for session \(sessionId.uuidString)")
            return payload.summary
        } catch {
            self.logger.warning("Memory distillation failed for session \(sessionId.uuidString): \(error.localizedDescription)")

            do {
                try self.memoryFileManager.writeSummary(sessionId: sessionId, content: SessionSummary.placeholder.renderMarkdown())
                await self.memoryIndex.rebuild()
            } catch {
                self.logger.error("Failed to write placeholder summary for session \(sessionId.uuidString): \(error.localizedDescription)")
            }

            return SessionSummary.placeholder
        }
    }

    // MARK: - Payload Generation

    private func generatePayload(
        prompt: String,
        transcript: String,
        existingMemoryContext: String,
        sessionId: UUID,
        timestamp: Date
    ) async throws -> DistillationPayload {
        let baseMessages = [
            LLMMessage(role: .system, content: prompt),
            LLMMessage(
                role: .user,
                content: Self.distillationInput(
                    transcript: transcript,
                    existingMemoryContext: existingMemoryContext
                )
            )
        ]

        var messages = baseMessages
        var lastParsingError: Error?

        for attempt in 1...self.maxRetries {
            let response = try await self.generateResponse(messages: messages)

            do {
                return try Self.parsePayload(from: response, sessionId: sessionId, timestamp: timestamp)
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
        let filteredMessages = messages.filter { $0.role != .tool }
        guard !filteredMessages.isEmpty else {
            return ""
        }

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let renderedLines = filteredMessages.compactMap { message -> String? in
            let timestamp = timestampFormatter.string(from: message.timestamp)
            let role = message.role.rawValue.uppercased()
            let content = message.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return nil
            }
            return "[\(timestamp)] \(role): \(content)"
        }

        return renderedLines.joined(separator: "\n")
    }

    private func shouldSkipMemoryDistillation(for messages: [Session.Message]) -> Bool {
        let userMessages = messages.filter { $0.role == .user }
        let totalUserCharacters = userMessages.reduce(0) { partialResult, message in
            partialResult + message.content.trimmingCharacters(in: .whitespacesAndNewlines).count
        }

        return userMessages.count < self.minimumUserMessageCount
            || totalUserCharacters < self.minimumUserCharacterCount
    }

    private func loadExistingMemoryContext(limit: Int) -> String {
        guard let memoryContent = try? String(contentsOf: self.memoryFileManager.memoryFileURL, encoding: .utf8) else {
            return "No existing memory entries."
        }

        let trimmed = memoryContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "No existing memory entries."
        }

        let prioritized = Self.prioritizedMemoryContext(from: trimmed)
        return Self.truncate(prioritized, limit: limit)
    }

    private static func prioritizedMemoryContext(from content: String) -> String {
        let sectionPriority: [MemoryEntry.Section] = [.profile, .preferences, .people, .projects, .ongoingGoals]
        let prioritizedSections = sectionPriority.compactMap { section in
            Self.sectionBlock(heading: section.heading, in: content)
        }

        guard !prioritizedSections.isEmpty else {
            return content
        }

        return prioritizedSections.joined(separator: "\n\n")
    }

    private static func sectionBlock(heading: String, in content: String) -> String? {
        guard let headingRange = content.range(of: heading) else {
            return nil
        }

        let afterHeading = content[headingRange.upperBound...]
        let nextHeadingRange = afterHeading.range(of: "\n## ")
        let sectionSlice: Substring
        if let nextHeadingRange {
            sectionSlice = content[headingRange.lowerBound..<nextHeadingRange.lowerBound]
        } else {
            sectionSlice = content[headingRange.lowerBound...]
        }

        let sectionContent = String(sectionSlice).trimmingCharacters(in: .whitespacesAndNewlines)
        return sectionContent.isEmpty ? nil : sectionContent
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let upperBound = text.index(text.startIndex, offsetBy: limit)
        let truncated = text[text.startIndex..<upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(truncated)\n...[truncated]"
    }

    private static func distillationInput(transcript: String, existingMemoryContext: String) -> String {
        return """
Transcript:

\(transcript)

Here is what Ora already remembers (MEMORY.md):
---
\(existingMemoryContext)
---

Only extract NEW information not already captured above.
If the conversation adds nothing new, return empty memory_entries.
"""
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
You are Ora's memory distiller.
You are given a session transcript and existing MEMORY.md context.
Extract only durable, user-relevant memory that is NEW compared to existing memory.

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
  "memory_entries": [
    {
      "section": "profile|preferences|people|projects|ongoing_goals",
      "tag": "fact|preference|fact_sensitive",
      "content": "string",
      "normalized_key": "optional-string"
    }
  ]
}

Rules:
- Section definitions:
  - profile: identity, demographics, role, location, stable background facts.
  - preferences: explicit likes/dislikes or stated defaults.
  - people: named individuals and relationship to user.
  - projects: active named projects or concrete workstreams.
  - ongoing_goals: recurring objectives or long-running commitments.
- Do NOT extract greetings, small talk, tool mechanics, audit IDs/UUIDs, session behavior, or assistant action restatements.
- If conversation adds no truly new durable memory, return empty memory_entries.
- Aim for 0-5 memory entries per session; most sessions should produce 0-2 entries.
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

    private static func parsePayload(
        from response: String,
        sessionId: UUID,
        timestamp: Date
    ) throws -> DistillationPayload {
        let cleaned = Self.cleanResponse(response)

        if let payload = try Self.decodePayload(candidate: cleaned, sessionId: sessionId, timestamp: timestamp) {
            return payload
        }

        for candidate in Self.extractJSONObjectCandidates(from: cleaned) {
            if let payload = try Self.decodePayload(candidate: candidate, sessionId: sessionId, timestamp: timestamp) {
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

    private static func decodePayload(
        candidate: String,
        sessionId: UUID,
        timestamp: Date
    ) throws -> DistillationPayload? {
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
            return envelope.toPayload(sessionId: sessionId, timestamp: timestamp)
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

