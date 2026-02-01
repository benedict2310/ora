//
//  MailListMailboxesTool.swift
//  Ora
//
//  List mailboxes in Mail
//

import Foundation
import os

struct MailListMailboxesTool: Tool {
    let name = "mail.list_mailboxes"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailListMailboxesTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List mailboxes in Apple Mail (optionally filtered by account).",
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

        Self.logger.info(
            "mail.list_mailboxes start accountLength=\(account?.count ?? 0, privacy: .public)"
        )

        let script = MailAppleScript.listMailboxesScript()
        let arguments = [account ?? ""]

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

        Self.logger.info(
            "mail.list_mailboxes completed duration=\(String(format: "%.2f", result.duration), privacy: .public)s stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .array(let items) = data else {
            throw MailToolError.invalidResponse
        }

        let summary = Self.summary(count: items.count, account: account)
        Self.logger.info("Listed \(items.count, privacy: .public) mailboxes")
        return .success(.array(items), summary: summary)
    }

    // MARK: - Helpers

    private static func optionalString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func summary(count: Int, account: String?) -> String {
        let accountClause = account.map { " in \($0)" } ?? ""
        if count == 0 {
            return "No mailboxes found\(accountClause)."
        } else if count == 1 {
            return "Found 1 mailbox\(accountClause)."
        } else {
            return "Found \(count) mailboxes\(accountClause)."
        }
    }
}
