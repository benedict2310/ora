//
//  MessagesSendTool.swift
//  Ora
//
//  Send a message via Messages (requires confirmation)
//

import Foundation
import os

struct MessagesSendTool: Tool {
    let name = "messages.send"
    let kind: ToolKind = .mutate

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MessagesSendTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Send an iMessage or SMS via Messages. Requires confirmation.",
            parameters: [
                "handle": ParameterSchema(type: "string", description: "Recipient handle (phone number or email)"),
                "message": ParameterSchema(type: "string", description: "Message text"),
                "service": ParameterSchema(type: "string", description: "Optional service hint: iMessage, SMS, or RCS")
            ],
            requiredParameters: ["handle", "message"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let handle = args["handle"]?.stringValue, !handle.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: handle")
        }
        guard let message = args["message"]?.stringValue, !message.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: message")
        }
        _ = handle
        _ = message
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let handle = args["handle"]?.stringValue ?? ""
        let message = args["message"]?.stringValue ?? ""
        let serviceHint = Self.normalizeService(args["service"]?.stringValue)

        let serviceValue = serviceHint ?? ""
        Self.logger.info(
            "messages.send start handleLength=\(handle.count, privacy: .public) messageLength=\(message.count, privacy: .public) service=\(serviceValue, privacy: .public)"
        )

        let script = MessagesAppleScript.sendMessageScript(handle: handle, message: message, service: serviceHint)
        let arguments = [handle, message, serviceHint ?? ""]

        let result: AppleScriptResult
        do {
            result = try await runner.execute(script: script, arguments: arguments, config: .json())
        } catch let error as AppleScriptError {
            let details = MessagesToolError.safeLogDetails(from: error)
            let message = MessagesToolError.sanitizedMessage(from: error)
            Self.logger.error(
                "\(name, privacy: .public) failed: type=\(details.type, privacy: .public) app=\(details.app, privacy: .public) code=\(details.code, privacy: .public) message=\(message, privacy: .public)"
            )
            throw MessagesToolError.fromAppleScriptError(error)
        }

        Self.logger.info(
            "messages.send AppleScript completed duration=\(String(format: "%.2f", result.duration), privacy: .public)s stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let data = try MessagesAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MessagesToolError.invalidResponse
        }

        let summary = Self.summary(handle: handle, message: message)
        Self.logger.info("Sent message to handle length: \(handle.count, privacy: .public)")
        return .success(.object(dict), summary: summary)
    }

    // MARK: - Helpers

    private static func normalizeService(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let lowercased = value.lowercased()
        switch lowercased {
        case "imessage":
            return "iMessage"
        case "sms":
            return "SMS"
        case "rcs":
            return "RCS"
        default:
            return nil
        }
    }

    private static func summary(handle: String, message: String) -> String {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedHandle.isEmpty {
            return "Sent message."
        }
        if preview.isEmpty {
            return "Sent message to \(trimmedHandle)."
        }
        return "Sent message to \(trimmedHandle): '\(preview)'."
    }
}
