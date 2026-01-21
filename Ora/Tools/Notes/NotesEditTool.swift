//
//  NotesEditTool.swift
//  Ora
//
//  Edit or append to an existing note (requires confirmation)
//

import Foundation
import os

struct NotesEditTool: Tool {
    let name = "notes.edit_note"
    let kind: ToolKind = .mutate

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "NotesEditTool")

    private enum EditMode: String {
        case append
        case replace
    }

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Edit a note by ID. mode: append or replace (default append). Requires confirmation.",
            parameters: [
                "note_id": ParameterSchema(type: "string", description: "Note identifier from notes.search_notes"),
                "text": ParameterSchema(type: "string", description: "Text to append or replace"),
                "mode": ParameterSchema(type: "string", description: "append or replace (default append)")
            ],
            requiredParameters: ["note_id", "text"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let noteID = args["note_id"]?.stringValue, !noteID.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: note_id")
        }

        guard let text = args["text"]?.stringValue, !text.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: text")
        }

        if let mode = args["mode"]?.stringValue, Self.parseMode(mode) == nil {
            throw ToolHostError.validationFailed(name, "mode must be 'append' or 'replace'")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let noteID = args["note_id"]?.stringValue ?? ""
        let text = args["text"]?.stringValue ?? ""
        let mode = Self.parseMode(args["mode"]?.stringValue) ?? .append

        let script = NotesAppleScript.editNoteScript(
            noteID: noteID,
            text: text,
            mode: mode.rawValue
        )

        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, config: .json())
        } catch let error as AppleScriptError {
            throw NotesToolError.fromAppleScriptError(error)
        }

        let data = try NotesAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw NotesToolError.invalidResponse
        }

        let title = dict["title"]?.stringValue ?? ""
        let summary = Self.summary(title: title, mode: mode)

        Self.logger.info("Edited note: \(title, privacy: .private)")
        return .success(.object(dict), summary: summary)
    }

    // MARK: - Helpers

    private static func parseMode(_ mode: String?) -> EditMode? {
        guard let mode = mode?.lowercased(), !mode.isEmpty else {
            return nil
        }
        return EditMode(rawValue: mode)
    }

    private static func summary(title: String, mode: EditMode) -> String {
        let displayTitle = title.isEmpty ? "note" : "note '\(title)'"
        switch mode {
        case .append:
            return "Appended to \(displayTitle)."
        case .replace:
            return "Replaced \(displayTitle)."
        }
    }
}
