//
//  MailRecentTool.swift
//  Ora
//
//  List recent Mail messages (headers only).
//

import Foundation
import os

struct MailRecentTool: Tool {
    let name = "mail.recent"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailRecentTool")

    private static let defaultLimit = 10
    private static let maxLimit = 50

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List recent Mail messages (headers only).",
            parameters: [
                "mailbox": ParameterSchema(type: "string", description: "Mailbox name filter (optional)"),
                "account": ParameterSchema(type: "string", description: "Mail account name filter (optional)"),
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
        let mailbox = Self.optionalString(args["mailbox"]?.stringValue)
        let account = Self.optionalString(args["account"]?.stringValue)
        let limit = Self.normalizedLimit(args["limit"]?.numberValue)

        Self.logger.info(
            "mail.recent start mailboxLength=\(mailbox?.count ?? 0) accountLength=\(account?.count ?? 0) limit=\(limit)"
        )

        let script = MailAppleScript.recentMessagesScript()
        let arguments = [mailbox ?? "", account ?? "", "\(limit)"]

        let result: AppleScriptResult
        do {
            result = try await self.runner.execute(script: script, arguments: arguments, config: .json())
        } catch let error as AppleScriptError {
            let details = MailToolError.safeLogDetails(from: error)
            let message = MailToolError.sanitizedMessage(from: error)
            Self.logger.error(
                "\(self.name) failed: type=\(details.type) app=\(details.app) code=\(details.code) message=\(message)"
            )
            throw MailToolError.fromAppleScriptError(error)
        }

        let parsed = try MailAppleScript.parseMessageList(result)
        if let errors = parsed.errors {
            Self.logger.warning("mail.recent partial failures: \(errors, privacy: .private)")
        }

        let headers = parsed.messages.compactMap { MessageHeader(json: $0) }
        let limited = Array(headers.prefix(limit))

        let summary = Self.summary(count: limited.count, mailbox: mailbox, account: account, hadErrors: parsed.errors != nil)
        Self.logger.info("mail.recent returned \(limited.count) messages")

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

    private static func summary(count: Int, mailbox: String?, account: String?, hadErrors: Bool) -> String {
        var filters: [String] = []
        if let mailbox = mailbox {
            filters.append("mailbox \(mailbox)")
        }
        if let account = account {
            filters.append("account \(account)")
        }
        let filterClause = filters.isEmpty ? "" : " for \(filters.joined(separator: ", "))"
        let errorClause = hadErrors ? " Some accounts could not be queried." : ""

        if count == 0 {
            return "No recent emails found\(filterClause).\(errorClause)"
        }
        if count == 1 {
            return "Found 1 recent email\(filterClause).\(errorClause)"
        }
        return "Found \(count) recent emails\(filterClause).\(errorClause)"
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

    func toJSON() -> JSONValue {
        .object([
            "message_id": .string(self.messageId),
            "subject": .string(self.subject),
            "from": .string(self.from),
            "date": .string(self.date),
            "mailbox": .string(self.mailbox),
            "account": .string(self.account)
        ])
    }
}
