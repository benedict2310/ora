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

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "NotesSearchTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search notes by title or body text",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Search query"),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 10)")
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let query = args["query"]?.stringValue ?? ""
        let limit = Self.normalizedLimit(args["limit"]?.numberValue)

        let script = NotesAppleScript.searchNotesScript(query: query, limit: limit)

        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, config: .json())
        } catch let error as AppleScriptError {
            throw NotesToolError.fromAppleScriptError(error)
        }

        let data = try NotesAppleScript.parseEnvelope(result)
        guard case .array(let notes) = data else {
            throw NotesToolError.invalidResponse
        }

        let summary = Self.summary(count: notes.count, query: query)
        Self.logger.info("Found \(notes.count) notes for query: \(query, privacy: .private)")

        return .success(.array(notes), summary: summary)
    }

    // MARK: - Helpers

    private static func normalizedLimit(_ value: Double?) -> Int {
        let limit = Int(value ?? 10)
        return min(max(limit, 1), 50)
    }

    private static func summary(count: Int, query: String) -> String {
        if count == 0 {
            return "No notes found matching '\(query)'."
        } else if count == 1 {
            return "Found 1 note matching '\(query)'."
        } else {
            return "Found \(count) notes matching '\(query)'."
        }
    }
}
