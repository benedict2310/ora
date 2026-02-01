//
//  NotesRecentTool.swift
//  Ora
//
//  List recently modified notes.
//

import Foundation
import os

struct NotesRecentTool: Tool {
    let name = "notes.recent"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "NotesRecentTool")

    private static let defaultLimit = 10
    private static let maxLimit = 50

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List recently modified notes (titles only).",
            parameters: [
                "folder": ParameterSchema(type: "string", description: "Folder name filter (optional)"),
                "account": ParameterSchema(type: "string", description: "Account name filter (optional)"),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 10, max 50)")
            ],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        // No required parameters
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let folder = Self.optionalString(args["folder"]?.stringValue)
        let account = Self.optionalString(args["account"]?.stringValue)
        let limit = Self.normalizedLimit(args["limit"]?.numberValue)

        Self.logger.info(
            "notes.recent start folderLength=\(folder?.count ?? 0) accountLength=\(account?.count ?? 0) limit=\(limit)"
        )

        let script = NotesAppleScript.recentNotesScript(folder: folder, account: account, limit: limit)

        let result: AppleScriptResult
        do {
            result = try await self.runner.execute(script: script, config: .json())
        } catch let error as AppleScriptError {
            throw NotesToolError.fromAppleScriptError(error)
        }

        let data = try NotesAppleScript.parseEnvelope(result)
        guard case .array(let items) = data else {
            throw NotesToolError.invalidResponse
        }

        let notes = items.compactMap { NoteSummary(json: $0) }
        let limited = Array(notes.prefix(limit))
        let summary = Self.summary(count: limited.count, folder: folder, account: account)

        Self.logger.info("notes.recent returned \(limited.count) notes")

        return .success(.array(limited.map { $0.toJSON() }), summary: summary)
    }

    // MARK: - Helpers

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

    private static func summary(count: Int, folder: String?, account: String?) -> String {
        var filters: [String] = []
        if let folder = folder {
            filters.append("folder \(folder)")
        }
        if let account = account {
            filters.append("account \(account)")
        }
        let filterClause = filters.isEmpty ? "" : " for \(filters.joined(separator: ", "))"

        if count == 0 {
            return "No recent notes found\(filterClause)."
        }
        if count == 1 {
            return "Found 1 recent note\(filterClause)."
        }
        return "Found \(count) recent notes\(filterClause)."
    }
}

// MARK: - Models

private struct NoteSummary: Sendable {
    let noteId: String
    let title: String
    let folder: String
    let modificationDate: String

    init?(json: JSONValue) {
        guard case .object(let dict) = json else {
            return nil
        }

        let noteId = dict["note_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !noteId.isEmpty else {
            return nil
        }

        self.noteId = noteId
        self.title = dict["title"]?.stringValue ?? ""
        self.folder = dict["folder"]?.stringValue ?? ""
        self.modificationDate = dict["modification_date"]?.stringValue ?? ""
    }

    func toJSON() -> JSONValue {
        .object([
            "note_id": .string(self.noteId),
            "title": .string(self.title),
            "folder": .string(self.folder),
            "modification_date": .string(self.modificationDate)
        ])
    }
}
