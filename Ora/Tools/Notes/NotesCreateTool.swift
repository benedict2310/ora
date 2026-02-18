//
//  NotesCreateTool.swift
//  Ora
//
//  Create a note in Apple Notes (requires confirmation)
//

import Foundation
import os

struct NotesCreateTool: Tool {
    let name = "notes.create_note"
    let kind: ToolKind = .mutate

    private let runner: AppleScriptRunning
    private static let logger = Logger.ora(category: "NotesCreateTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a note in Apple Notes. Requires confirmation.",
            parameters: [
                "body": ParameterSchema(type: "string", description: "Note body text"),
                "title": ParameterSchema(type: "string", description: "Note title (optional)"),
                "folder": ParameterSchema(type: "string", description: "Folder name (optional)"),
                "account": ParameterSchema(type: "string", description: "Account name (optional)")
            ],
            requiredParameters: ["body"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let body = args["body"]?.stringValue, !body.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: body")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let body = args["body"]?.stringValue ?? ""
        let title = Self.optionalString(args["title"]?.stringValue)
        let folder = Self.optionalString(args["folder"]?.stringValue)
        let account = Self.optionalString(args["account"]?.stringValue)

        let script = NotesAppleScript.createNoteScript(
            title: title,
            body: body,
            folder: folder,
            account: account
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

        let noteTitle = dict["title"]?.stringValue ?? ""
        let folderName = dict["folder"]?.stringValue ?? ""
        let summary = Self.summary(title: noteTitle, folder: folderName)

        Self.logger.info("Created note: \(noteTitle, privacy: .private)")
        return .success(.object(dict), summary: summary)
    }

    // MARK: - Helpers

    private static func optionalString(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func summary(title: String, folder: String) -> String {
        let hasTitle = !title.isEmpty
        let hasFolder = !folder.isEmpty

        switch (hasTitle, hasFolder) {
        case (true, true):
            return "Created note '\(title)' in \(folder)."
        case (true, false):
            return "Created note '\(title)'."
        case (false, true):
            return "Created a note in \(folder)."
        case (false, false):
            return "Created a note."
        }
    }
}
