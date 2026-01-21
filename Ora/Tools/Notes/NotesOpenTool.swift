//
//  NotesOpenTool.swift
//  Ora
//
//  Open a note by ID in Apple Notes
//

import Foundation
import os

struct NotesOpenTool: Tool {
    let name = "notes.open_note"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "NotesOpenTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a note in Apple Notes by ID",
            parameters: [
                "note_id": ParameterSchema(type: "string", description: "Note identifier")
            ],
            requiredParameters: ["note_id"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let noteId = args["note_id"]?.stringValue, !noteId.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: note_id")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let noteId = args["note_id"]?.stringValue ?? ""
        let script = NotesAppleScript.openNoteScript(noteID: noteId)

        let result: AppleScriptResult
        do {
            result = try await ExternalFocusTracker.shared.withExternalOperation {
                try await runner.execute(script: script, config: .json())
            }
        } catch let error as AppleScriptError {
            throw NotesToolError.fromAppleScriptError(error)
        }

        let data = try NotesAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw NotesToolError.invalidResponse
        }

        let title = dict["title"]?.stringValue ?? ""
        let summary = title.isEmpty ? "Opened note." : "Opened note '\(title)'."

        Self.logger.info("Opened note: \(title, privacy: .private)")
        return .success(.object(dict), summary: summary)
    }
}
