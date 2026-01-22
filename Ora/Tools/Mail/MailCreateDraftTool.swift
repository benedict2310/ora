//
//  MailCreateDraftTool.swift
//  Ora
//
//  Create a draft email in Apple Mail (requires confirmation)
//

import Foundation
import os

struct MailCreateDraftTool: Tool {
    let name = "mail.create_draft"
    let kind: ToolKind = .mutate

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailCreateDraftTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create an email draft in Apple Mail. Requires confirmation.",
            parameters: [
                "to": ParameterSchema(type: "string", description: "Recipient email address(es), comma-separated"),
                "cc": ParameterSchema(type: "string", description: "CC recipient(s), comma-separated (optional)"),
                "bcc": ParameterSchema(type: "string", description: "BCC recipient(s), comma-separated (optional)"),
                "subject": ParameterSchema(type: "string", description: "Email subject"),
                "body": ParameterSchema(type: "string", description: "Email body"),
                "account": ParameterSchema(type: "string", description: "Mail account name (optional)")
            ],
            requiredParameters: ["to", "subject", "body"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let to = args["to"]?.stringValue, !to.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: to")
        }
        guard let subject = args["subject"]?.stringValue, !subject.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: subject")
        }
        guard let body = args["body"]?.stringValue, !body.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: body")
        }
        _ = to
        _ = subject
        _ = body
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let to = args["to"]?.stringValue ?? ""
        let cc = Self.optionalString(args["cc"]?.stringValue)
        let bcc = Self.optionalString(args["bcc"]?.stringValue)
        let subject = args["subject"]?.stringValue ?? ""
        let body = args["body"]?.stringValue ?? ""
        let account = Self.optionalString(args["account"]?.stringValue)

        let script = MailAppleScript.createDraftScript(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            account: account
        )

        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, config: .json())
        } catch let error as AppleScriptError {
            throw MailToolError.fromAppleScriptError(error)
        }

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MailToolError.invalidResponse
        }

        let subjectValue = dict["subject"]?.stringValue ?? subject
        let summary = Self.summary(to: to, subject: subjectValue)

        Self.logger.info("Created draft with subject: \(subjectValue, privacy: .private)")
        return .success(.object(dict), summary: summary)
    }

    // MARK: - Helpers

    private static func optionalString(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func summary(to: String, subject: String) -> String {
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (trimmedTo.isEmpty, trimmedSubject.isEmpty) {
        case (false, false):
            return "Created draft to \(trimmedTo) with subject '\(trimmedSubject)'."
        case (false, true):
            return "Created draft to \(trimmedTo)."
        case (true, false):
            return "Created draft '\(trimmedSubject)'."
        case (true, true):
            return "Created draft."
        }
    }
}
