//
//  DistillerOrchestrator.swift
//  Ora
//
//  Distillation payload decoding and validation helpers.
//

import Foundation

// MARK: - Distillation Payload

struct DistillationPayload: Sendable {
    let summary: SessionSummary
    let memoryEntries: [MemoryEntry]
}

struct DistillationEnvelope: Decodable {

    // MARK: - Constants

    private static let maxMemoryEntriesPerDistillation = 8
    private static let auditTokens = ["audit id", "audit_id", "audit-id"]
    private static let greetingPhrases = [
        "user greeted",
        "user said hello",
        "user consistently uses greeting"
    ]
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}\b"#,
        options: []
    )
    private static let toolMechanicsRegex = try! NSRegularExpression(
        pattern: #"^\s*(created|updated|deleted)\s+\d+.*\busing\b.*\btool\b"#,
        options: [.caseInsensitive]
    )

    let summary: DistilledSummary
    let memoryEntries: [DistilledMemoryEntry]

    enum CodingKeys: String, CodingKey {
        case summary
        case memoryEntries = "memory_entries"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.summary = try container.decode(DistilledSummary.self, forKey: .summary)

        if let structuredEntries = try? container.decode([DistilledMemoryEntry].self, forKey: .memoryEntries) {
            self.memoryEntries = structuredEntries
        } else {
            let legacyEntries = (try? container.decode([String].self, forKey: .memoryEntries)) ?? []
            self.memoryEntries = legacyEntries.map {
                DistilledMemoryEntry(
                    section: "profile",
                    tag: "fact",
                    content: $0,
                    normalizedKey: nil
                )
            }
        }
    }

    func toPayload(sessionId: UUID, timestamp: Date) -> DistillationPayload {
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

        let normalizedMemoryEntries = self.memoryEntries.compactMap { entry -> MemoryEntry? in
            let section = MemoryEntry.Section(rawSection: entry.section)
            let tag = MemoryEntry.Tag(rawTag: entry.tag) ?? .fact
            let content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let section, !content.isEmpty else {
                return nil
            }

            guard !Self.isLowValueContent(content) else {
                return nil
            }

            return MemoryEntry(
                section: section,
                tag: tag,
                content: content,
                sourceSessionID: sessionId,
                timestamp: timestamp,
                normalizedKey: entry.normalizedKey
            )
        }

        let cappedEntries = Array(normalizedMemoryEntries.prefix(Self.maxMemoryEntriesPerDistillation))
        return DistillationPayload(summary: summary, memoryEntries: cappedEntries)
    }

    private static func isLowValueContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        if trimmed.count < 20 {
            return true
        }

        let lowercase = trimmed.lowercased()
        if Self.auditTokens.contains(where: { lowercase.contains($0) }) {
            return true
        }

        if Self.greetingPhrases.contains(where: { lowercase.contains($0) }) {
            return true
        }

        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if Self.uuidRegex.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
            return true
        }

        if Self.toolMechanicsRegex.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
            return true
        }

        return false
    }
}

struct DistilledSummary: Decodable {
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

struct DistilledDecision: Decodable {
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

struct DistilledMemoryEntry: Decodable {
    let section: String
    let tag: String
    let content: String
    let normalizedKey: String?

    enum CodingKeys: String, CodingKey {
        case section
        case tag
        case content
        case normalizedKey = "normalized_key"
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
