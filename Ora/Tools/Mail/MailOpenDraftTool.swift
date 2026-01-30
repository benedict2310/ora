//
//  MailOpenDraftTool.swift
//  Ora
//
//  Open a draft email in Apple Mail
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
            description: "Open a draft email in Apple Mail by ID",
            parameters: [
                "draft_id": ParameterSchema(type: "string", description: "Draft identifier")
            ],
            requiredParameters: ["draft_id"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let draftId = args["draft_id"]?.stringValue, !draftId.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: draft_id")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let draftId = args["draft_id"]?.stringValue ?? ""
        let script = MailAppleScript.openDraftScript(draftID: draftId)

        let result: AppleScriptResult
        do {
            result = try await ExternalFocusTracker.shared.withExternalOperation {
                try await runner.execute(script: script, config: .json())
            }
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

        let subjectValue = dict["subject"]?.stringValue ?? ""
        let summary = subjectValue.isEmpty ? "Opened draft." : "Opened draft '\(subjectValue)'."

        Self.logger.info("Opened draft: \(subjectValue, privacy: .private)")
        return .success(.object(dict), summary: summary)
    }
}
