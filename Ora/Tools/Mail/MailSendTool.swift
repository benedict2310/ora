//
//  MailSendTool.swift
//  Ora
//
//  Send an email via Apple Mail (requires confirmation)
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
                "to": ParameterSchema(type: "string", description: "Recipient email address(es), comma-separated"),
                "subject": ParameterSchema(type: "string", description: "Email subject"),
                "body": ParameterSchema(type: "string", description: "Email body")
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

        let script = MailAppleScript.sendEmailScript(to: to, subject: subject, body: body)

        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, config: .json())
        } catch let error as AppleScriptError {
            let details = MailToolError.safeLogDetails(from: error)
            let message = MailToolError.sanitizedMessage(from: error)
            Self.logger.error(
                "\(name, privacy: .public) failed: type=\(details.type, privacy: .public) app=\(details.app, privacy: .public) code=\(details.code, privacy: .public) message=\(message, privacy: .public)"
            )
            throw MailToolError.fromAppleScriptError(error)
        }

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MailToolError.invalidResponse
        }

        let subjectValue = dict["subject"]?.stringValue ?? subject
        let summary = Self.summary(to: to, subject: subjectValue)

        Self.logger.info("Sent email with subject: \(subjectValue, privacy: .private)")
        return .success(.object(dict), summary: summary)
    }

    // MARK: - Helpers

    private static func summary(to: String, subject: String) -> String {
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (trimmedTo.isEmpty, trimmedSubject.isEmpty) {
        case (false, false):
            return "Sent email to \(trimmedTo) with subject '\(trimmedSubject)'."
        case (false, true):
            return "Sent email to \(trimmedTo)."
        case (true, false):
            return "Sent email '\(trimmedSubject)'."
        case (true, true):
            return "Sent email."
        }
    }
}
