//
//  NotesListFoldersTool.swift
//  Ora
//
//  List folders in Apple Notes
//

import Foundation
import os

struct NotesListFoldersTool: Tool {
    let name = "notes.list_folders"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "NotesListFoldersTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List folders in Apple Notes",
            parameters: [
                "account": ParameterSchema(type: "string", description: "Account name filter (optional)")
            ],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        // No required parameters
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let account = Self.optionalString(args["account"]?.stringValue)
        let script = NotesAppleScript.listFoldersScript(account: account)

        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, config: .json())
        } catch let error as AppleScriptError {
            throw NotesToolError.fromAppleScriptError(error)
        }

        let data = try NotesAppleScript.parseEnvelope(result)
        guard case .array(let folders) = data else {
            throw NotesToolError.invalidResponse
        }

        let summary = Self.summary(count: folders.count, account: account)
        Self.logger.info("Listed \(folders.count) folders")

        return .success(.array(folders), summary: summary)
    }

    // MARK: - Helpers

    private static func optionalString(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func summary(count: Int, account: String?) -> String {
        let accountClause = account.map { " in \($0)" } ?? ""
        if count == 0 {
            return "No folders found\(accountClause)."
        } else if count == 1 {
            return "Found 1 folder\(accountClause)."
        } else {
            return "Found \(count) folders\(accountClause)."
        }
    }
}
