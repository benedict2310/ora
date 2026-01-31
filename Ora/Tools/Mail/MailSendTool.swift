//
//  MailSendTool.swift
//  Ora
//
//  Send an email via Mail (requires confirmation)
//

import Foundation
import os

struct MailSendTool: Tool {
    let name = "mail.send"
    let kind: ToolKind = .mutate

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailSendTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Send an email via Apple Mail. Requires confirmation.",
            parameters: [
                "to": ParameterSchema(type: "string", description: "Comma-separated recipient email addresses"),
                "subject": ParameterSchema(type: "string", description: "Email subject line"),
                "body": ParameterSchema(type: "string", description: "Email body text"),
                "cc": ParameterSchema(type: "string", description: "Comma-separated CC email addresses (optional)"),
                "bcc": ParameterSchema(type: "string", description: "Comma-separated BCC email addresses (optional)"),
                "account": ParameterSchema(type: "string", description: "Mail account name to send from (optional)")
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
        let subject = args["subject"]?.stringValue ?? ""
        let body = args["body"]?.stringValue ?? ""
        let cc = args["cc"]?.stringValue ?? ""
        let bcc = args["bcc"]?.stringValue ?? ""
        let account = args["account"]?.stringValue ?? ""

        Self.logger.info(
            "mail.send start toLength=\(to.count, privacy: .public) subjectLength=\(subject.count, privacy: .public)"
        )

        let script = MailAppleScript.sendScript()
        let arguments = [to, subject, body, cc, bcc, account]

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
            "mail.send completed duration=\(String(format: "%.2f", result.duration), privacy: .public)s stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MailToolError.invalidResponse
        }

        let summary = Self.summary(to: to, subject: subject)
        Self.logger.info("Sent email to length: \(to.count, privacy: .public)")
        return .success(.object(dict), summary: summary)
    }

    // MARK: - Helpers

    private static func summary(to: String, subject: String) -> String {
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedTo.isEmpty {
            return "Sent email."
        }
        if trimmedSubject.isEmpty {
            return "Sent email to \(trimmedTo)."
        }
        return "Sent email to \(trimmedTo): '\(trimmedSubject)'."
    }
}
