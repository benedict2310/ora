//
//  MailCreateDraftTool.swift
//  Ora
//
//  Create a draft email in Mail (requires confirmation)
//

import Foundation
import os

struct MailCreateDraftTool: Tool {
    let name = "mail.create_draft"
    let kind: ToolKind = .mutate

    private let runner: AppleScriptRunning
    private static let logger = Logger.ora(category: "MailCreateDraftTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a draft email in Apple Mail. Requires confirmation.",
            parameters: [
                "to": ParameterSchema(type: "string", description: "Comma-separated recipient email addresses"),
                "subject": ParameterSchema(type: "string", description: "Email subject line (optional)"),
                "body": ParameterSchema(type: "string", description: "Email body text (optional)"),
                "cc": ParameterSchema(type: "string", description: "Comma-separated CC email addresses (optional)"),
                "bcc": ParameterSchema(type: "string", description: "Comma-separated BCC email addresses (optional)"),
                "account": ParameterSchema(type: "string", description: "Mail account name to send from (optional)")
            ],
            requiredParameters: ["to"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let to = args["to"]?.stringValue, !to.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: to")
        }
        _ = to
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let to = args["to"]?.stringValue ?? ""
        let subject = args["subject"]?.stringValue ?? ""
        let body = args["body"]?.stringValue ?? ""
        let cc = args["cc"]?.stringValue ?? ""
        let bcc = args["bcc"]?.stringValue ?? ""
        let account = args["account"]?.stringValue ?? ""

        Self.logger.info(
            "mail.create_draft start toLength=\(to.count, privacy: .public) subjectLength=\(subject.count, privacy: .public)"
        )

        let script = MailAppleScript.createDraftScript()
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
            "mail.create_draft completed duration=\(String(format: "%.2f", result.duration), privacy: .public)s stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MailToolError.invalidResponse
        }

        let draftSubject = dict["subject"]?.stringValue ?? subject
        let summary: String
        if draftSubject.isEmpty {
            summary = "Created draft to \(to)."
        } else {
            summary = "Created draft: '\(draftSubject)'."
        }
        Self.logger.info("Created mail draft subject length: \(subject.count, privacy: .public)")
        return .success(.object(dict), summary: summary)
    }
}
