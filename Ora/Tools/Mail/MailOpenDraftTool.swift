//
//  MailOpenDraftTool.swift
//  Ora
//
//  Open a draft email window in Mail
//

import Foundation
import os

struct MailOpenDraftTool: Tool {
    let name = "mail.open_draft"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailOpenDraftTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a draft email window in Apple Mail.",
            parameters: [
                "draft_id": ParameterSchema(type: "string", description: "Draft message ID (from mail.create_draft result)")
            ],
            requiredParameters: ["draft_id"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let draftId = args["draft_id"]?.stringValue, !draftId.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: draft_id")
        }
        _ = draftId
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let draftId = args["draft_id"]?.stringValue ?? ""

        Self.logger.info(
            "mail.open_draft start draftIdLength=\(draftId.count, privacy: .public)"
        )

        let script = MailAppleScript.openDraftScript()
        let arguments = [draftId]

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
            "mail.open_draft completed duration=\(String(format: "%.2f", result.duration), privacy: .public)s stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let data = try MailAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MailToolError.invalidResponse
        }

        let draftSubject = dict["subject"]?.stringValue ?? "draft"
        let summary = "Opened draft: '\(draftSubject)'."
        Self.logger.info("Opened mail draft")
        return .success(.object(dict), summary: summary)
    }
}
