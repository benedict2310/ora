//
//  MailOpenMessageTool.swift
//  Ora
//
//  Open an email message in Mail
//

import Foundation
import os

struct MailOpenMessageTool: Tool {
    let name = "mail.open_message"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger.ora(category: "MailOpenMessageTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open an email message in Apple Mail by message_id.",
            parameters: [
                "message_id": ParameterSchema(type: "string", description: "Message ID from mail.search")
            ],
            requiredParameters: ["message_id"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let messageId = args["message_id"]?.stringValue,
              !messageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: message_id")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let messageId = args["message_id"]?.stringValue ?? ""

        Self.logger.info("mail.open_message start messageIdLength=\(messageId.count, privacy: .public)")

        let script = MailAppleScript.openMessageScript()
        let arguments = [messageId]

        let result: AppleScriptResult
        do {
            result = try await ExternalFocusTracker.shared.withExternalOperation {
                try await runner.execute(script: script, arguments: arguments, config: .json())
            }
        } catch let error as AppleScriptError {
            let details = MailToolError.safeLogDetails(from: error)
            let message = MailToolError.sanitizedMessage(from: error)
            Self.logger.error(
                "\(self.name, privacy: .public) failed: type=\(details.type, privacy: .public) app=\(details.app, privacy: .public) code=\(details.code, privacy: .public) message=\(message, privacy: .public)"
            )
            throw MailToolError.fromAppleScriptError(error)
        }

        Self.logger.info(
            "mail.open_message completed duration=\(String(format: "%.2f", result.duration), privacy: .public)s stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MailToolError.invalidResponse
        }

        let subject = dict["subject"]?.stringValue ?? ""
        let summary = subject.isEmpty ? "Opened email." : "Opened email: '\(subject)'."
        Self.logger.info("Opened mail message")
        return .success(.object(dict), summary: summary)
    }
}
