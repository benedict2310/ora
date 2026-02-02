//
//  MailSearchTool.swift
//  Ora
//
//  Search Mail messages by subject/sender with fuzzy fallback.
//

import Foundation
import os

struct MailSearchTool: Tool {
    let name = "mail.search"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailSearchTool")

    private static let defaultLimit = 5
    private static let maxLimit = 20
    private static let fuzzyThreshold: Double = 0.80
    private static let fuzzyCandidateLimit = 100

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search Mail by subject or sender (fuzzy fallback when exact search finds none).",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Search query (subject or sender)"),
                "mailbox": ParameterSchema(type: "string", description: "Mailbox name filter (optional)"),
                "account": ParameterSchema(type: "string", description: "Mail account name filter (optional)"),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 5, max 20)")
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let query = args["query"]?.stringValue ?? ""
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let mailbox = Self.optionalString(args["mailbox"]?.stringValue)
        let account = Self.optionalString(args["account"]?.stringValue)
        let limit = Self.normalizedLimit(args["limit"]?.numberValue)

        Self.logger.info(
            "mail.search start queryLength=\(normalizedQuery.count, privacy: .public) mailboxLength=\(mailbox?.count ?? 0, privacy: .public) accountLength=\(account?.count ?? 0, privacy: .public) limit=\(limit, privacy: .public)"
        )

        let exactMatches = try await self.fetchExactMatches(
            query: normalizedQuery,
            mailbox: mailbox,
            account: account,
            limit: limit
        )

        if !exactMatches.isEmpty {
            let summary = Self.summary(count: exactMatches.count, query: normalizedQuery, isFuzzy: false)
            Self.logger.info("mail.search exactResults=\(exactMatches.count, privacy: .public)")
            return .success(.array(exactMatches.map { $0.toJSON() }), summary: summary)
        }

        let candidates = try await self.fetchRecentMessages(
            mailbox: mailbox,
            account: account,
            limit: Self.fuzzyCandidateLimit
        )
        let fuzzyMatches = Self.fuzzyMatches(query: normalizedQuery, candidates: candidates, limit: limit)
        let summary = Self.summary(count: fuzzyMatches.count, query: normalizedQuery, isFuzzy: true)
        Self.logger.info(
            "mail.search fuzzyCandidates=\(candidates.count, privacy: .public) fuzzyResults=\(fuzzyMatches.count, privacy: .public)"
        )
        return .success(
            .array(fuzzyMatches.map { $0.header.toJSON(matchScore: $0.score) }),
            summary: summary
        )
    }

    // MARK: - Helpers

    private func fetchExactMatches(
        query: String,
        mailbox: String?,
        account: String?,
        limit: Int
    ) async throws -> [MessageHeader] {
        let script = MailAppleScript.searchMessagesScript()
        let arguments = [query, mailbox ?? "", account ?? "", "\(limit)"]

        let headers = try await self.runScript(script: script, arguments: arguments)
        return Array(headers.prefix(limit))
    }

    private func fetchRecentMessages(
        mailbox: String?,
        account: String?,
        limit: Int
    ) async throws -> [MessageHeader] {
        let script = MailAppleScript.recentMessagesScript()
        let arguments = [mailbox ?? "", account ?? "", "\(limit)"]
        return try await self.runScript(script: script, arguments: arguments)
    }

    private func runScript(script: String, arguments: [String]) async throws -> [MessageHeader] {
        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, arguments: arguments, config: .json())
        } catch let error as AppleScriptError {
            let details = MailToolError.safeLogDetails(from: error)
            let message = MailToolError.sanitizedMessage(from: error)
            Self.logger.error(
                "\(self.name, privacy: .public) failed: type=\(details.type, privacy: .public) app=\(details.app, privacy: .public) code=\(details.code, privacy: .public) message=\(message, privacy: .public)"
            )
            throw MailToolError.fromAppleScriptError(error)
        }

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .array(let items) = data else {
            throw MailToolError.invalidResponse
        }

        return items.compactMap { MessageHeader(json: $0) }
    }

    private static func fuzzyMatches(
        query: String,
        candidates: [MessageHeader],
        limit: Int
    ) -> [ScoredHeader] {
        let scored = candidates.map { header -> ScoredHeader in
            let subjectScore = StringSimilarity.jaroWinkler(query, header.subject)
            let fromScore = StringSimilarity.jaroWinkler(query, header.from)
            let score = max(subjectScore, fromScore)
            return ScoredHeader(header: header, score: score)
        }

        return scored
            .filter { $0.score >= fuzzyThreshold }
            .sorted { lhs, rhs in
                let delta = lhs.score - rhs.score
                if abs(delta) < 0.0001 {
                    return lhs.header.subject.lowercased() < rhs.header.subject.lowercased()
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func normalizedLimit(_ value: Double?) -> Int {
        let limit = Int(value ?? Double(defaultLimit))
        return min(max(limit, 1), maxLimit)
    }

    private static func optionalString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func summary(count: Int, query: String, isFuzzy: Bool) -> String {
        if count == 0 {
            return "No emails found matching '\(query)'."
        }
        let prefix = isFuzzy ? "possible " : ""
        if count == 1 {
            return "Found 1 \(prefix)email matching '\(query)'."
        }
        return "Found \(count) \(prefix)emails matching '\(query)'."
    }
}

// MARK: - Models

private struct MessageHeader: Sendable {
    let messageId: String
    let subject: String
    let from: String
    let date: String
    let mailbox: String
    let account: String

    init?(json: JSONValue) {
        guard case .object(let dict) = json else {
            return nil
        }

        let messageId = dict["message_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !messageId.isEmpty else {
            return nil
        }

        self.messageId = messageId
        self.subject = dict["subject"]?.stringValue ?? ""
        self.from = dict["from"]?.stringValue ?? ""
        self.date = dict["date"]?.stringValue ?? ""
        self.mailbox = dict["mailbox"]?.stringValue ?? ""
        self.account = dict["account"]?.stringValue ?? ""
    }

    func toJSON(matchScore: Double? = nil) -> JSONValue {
        var dict: [String: JSONValue] = [
            "message_id": .string(self.messageId),
            "subject": .string(self.subject),
            "from": .string(self.from),
            "date": .string(self.date),
            "mailbox": .string(self.mailbox),
            "account": .string(self.account)
        ]

        if let score = matchScore {
            dict["match_score"] = .number(Double(Int(score * 100)) / 100.0)
        }

        return .object(dict)
    }
}

private struct ScoredHeader: Sendable {
    let header: MessageHeader
    let score: Double
}
