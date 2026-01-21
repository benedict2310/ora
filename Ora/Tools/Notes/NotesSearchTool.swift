//
//  NotesSearchTool.swift
//  Ora
//
//  Search notes in Apple Notes
//

import Foundation
import os

struct NotesSearchTool: Tool {
    let name = "notes.search_notes"
    let kind: ToolKind = .read

    private static let minQueryLength = 3
    private static let blockedQueries: Set<String> = [
        "all",
        "everything",
        "notes",
        "note",
        "recent",
        "latest"
    ]

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "NotesSearchTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search notes by title text (use a specific keyword; default limit 5, max 20)",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Search query"),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 5, max 20)")
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }

        let normalized = Self.normalizeQuery(query)
        guard Self.isQuerySpecific(normalized) else {
            throw ToolHostError.validationFailed(
                name,
                "Query is too broad. Use a more specific keyword (at least 3 letters)."
            )
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let query = Self.normalizeQuery(args["query"]?.stringValue ?? "")
        let limit = Self.normalizedLimit(args["limit"]?.numberValue)

        Self.logger.info("Searching notes for query: \(query, privacy: .public)")

        let script = NotesAppleScript.searchNotesScript(query: query, limit: limit)

        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, config: .json())
        } catch let error as AppleScriptError {
            throw NotesToolError.fromAppleScriptError(error)
        }

        let data = try NotesAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data,
              case .array(let notes) = dict["items"] else {
            throw NotesToolError.invalidResponse
        }

        let returnedCount = notes.count
        let totalCount = Int(dict["total_count"]?.numberValue ?? Double(returnedCount))
        let remainingCount = max(totalCount - returnedCount, 0)
        let truncated = remainingCount > 0

        var responseDict = dict
        responseDict["total_count"] = .number(Double(totalCount))
        responseDict["returned_count"] = .number(Double(returnedCount))
        responseDict["remaining_count"] = .number(Double(remainingCount))
        responseDict["truncated"] = .bool(truncated)
        if truncated {
            responseDict["recommendation"] = .string("Try a more specific query to see more results.")
        }

        let summary = Self.summary(returnedCount: returnedCount, totalCount: totalCount, query: query)
        Self.logger.info("Notes search returned \(returnedCount) of \(totalCount)")
        Self.logger.info("Found \(totalCount) notes for query: \(query, privacy: .private)")

        return .success(.object(responseDict), summary: summary)
    }

    // MARK: - Helpers

    private static func normalizedLimit(_ value: Double?) -> Int {
        let limit = Int(value ?? 5)
        return min(max(limit, 1), 20)
    }

    private static func summary(returnedCount: Int, totalCount: Int, query: String) -> String {
        if totalCount == 0 {
            return "No notes found matching '\(query)'."
        }
        if totalCount == 1 {
            return "Found 1 note matching '\(query)'."
        }

        if returnedCount >= totalCount {
            return "Found \(totalCount) notes matching '\(query)'."
        }

        let remaining = max(totalCount - returnedCount, 0)
        return "Found \(totalCount) notes matching '\(query)'. Showing \(returnedCount) of \(totalCount); \(remaining) more not shown — try a more specific query."
    }

    private static func normalizeQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = Self.stripWrappingQuotes(trimmed)
        return Self.stripOuterPunctuation(unquoted)
    }

    private static func isQuerySpecific(_ query: String) -> Bool {
        let stripped = query.filter { $0.isLetter || $0.isNumber }
        guard stripped.count >= minQueryLength else {
            return false
        }

        let tokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        return tokens.contains { token in
            token.count >= minQueryLength && !blockedQueries.contains(token)
        }
    }

    private static func stripWrappingQuotes(_ query: String) -> String {
        guard query.count >= 2 else { return query }
        let first = query.first
        let last = query.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(query.dropFirst().dropLast())
        }
        return query
    }

    private static func stripOuterPunctuation(_ query: String) -> String {
        let punctuation = CharacterSet(charactersIn: ".,!?;:")
        return query.trimmingCharacters(in: punctuation)
    }
}
