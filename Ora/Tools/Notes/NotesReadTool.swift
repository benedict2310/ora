//
//  NotesReadTool.swift
//  Ora
//
//  Read a note's plain text content
//

import Foundation
import os

struct NotesReadTool: Tool {
    let name = "notes.read_note"
    let kind: ToolKind = .read

    private static let defaultMaxChars = 1200
    private static let maxMaxChars = 4000

    private let runner: AppleScriptRunning
    private static let logger = Logger.ora(category: "NotesReadTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Read a note by ID and return plain text (default max 1200 chars, max 4000).",
            parameters: [
                "note_id": ParameterSchema(type: "string", description: "Note identifier from notes.search_notes"),
                "max_chars": ParameterSchema(type: "number", description: "Maximum characters to return (default 1200, max 4000)")
            ],
            requiredParameters: ["note_id"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let noteID = args["note_id"]?.stringValue, !noteID.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: note_id")
        }

        if let maxChars = args["max_chars"]?.numberValue, maxChars <= 0 {
            throw ToolHostError.validationFailed(name, "max_chars must be greater than 0")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let noteID = args["note_id"]?.stringValue ?? ""
        let maxChars = Self.normalizedMaxChars(args["max_chars"]?.numberValue)

        let script = NotesAppleScript.readNoteScript(noteID: noteID, maxChars: maxChars)

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
        let totalChars = Int(dict["total_chars"]?.numberValue ?? 0)
        let returnedChars = Int(dict["returned_chars"]?.numberValue ?? 0)
        let remainingChars = Int(dict["remaining_chars"]?.numberValue ?? 0)
        let truncated = dict["truncated"]?.boolValue ?? (remainingChars > 0)

        var responseDict = dict
        responseDict["total_chars"] = .number(Double(totalChars))
        responseDict["returned_chars"] = .number(Double(returnedChars))
        responseDict["remaining_chars"] = .number(Double(remainingChars))
        responseDict["truncated"] = .bool(truncated)
        if truncated {
            responseDict["recommendation"] = .string("Ask to read more or lower max_chars.")
        }

        let summary = Self.summary(
            title: title,
            returnedChars: returnedChars,
            totalChars: totalChars,
            truncated: truncated
        )

        Self.logger.info("Read note: \(title, privacy: .private)")
        return .success(.object(responseDict), summary: summary)
    }

    // MARK: - Helpers

    private static func normalizedMaxChars(_ value: Double?) -> Int {
        let maxChars = Int(value ?? Double(defaultMaxChars))
        return min(max(maxChars, 1), maxMaxChars)
    }

    private static func summary(title: String, returnedChars: Int, totalChars: Int, truncated: Bool) -> String {
        let displayTitle = title.isEmpty ? "note" : "note '\(title)'"

        if totalChars == 0 {
            return "\(displayTitle.capitalized) is empty."
        }

        if truncated && returnedChars < totalChars {
            let remaining = max(totalChars - returnedChars, 0)
            return "Read \(displayTitle). Showing \(returnedChars) of \(totalChars) chars; \(remaining) more not shown — ask to read more."
        }

        return "Read \(displayTitle)."
    }
}
