//
//  MessagesOpenChatTool.swift
//  Ora
//
//  Open a chat in Messages
//

import Foundation
import os

struct MessagesOpenChatTool: Tool {
    let name = "messages.open_chat"
    let kind: ToolKind = .read

    private let runner: AppleScriptRunning
    private static let logger = Logger(subsystem: "com.ora.app", category: "MessagesOpenChatTool")

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a chat in Messages for a handle",
            parameters: [
                "handle": ParameterSchema(type: "string", description: "Recipient handle (phone number or email)"),
                "service": ParameterSchema(type: "string", description: "Optional service hint: iMessage, SMS, or RCS")
            ],
            requiredParameters: ["handle"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let handle = args["handle"]?.stringValue, !handle.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: handle")
        }
        guard Self.isResolvableHandle(handle) else {
            throw ToolHostError.validationFailed(
                name,
                "Handle must be a phone number or email address. Use contacts.search to resolve names."
            )
        }
        _ = handle
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let handle = args["handle"]?.stringValue ?? ""
        let serviceHint = Self.normalizeService(args["service"]?.stringValue)

        let serviceValue = serviceHint ?? ""
        Self.logger.info(
            "messages.open_chat start handleLength=\(handle.count, privacy: .public) service=\(serviceValue, privacy: .public)"
        )

        let script = MessagesAppleScript.openChatScript(handle: handle, service: serviceHint)
        let arguments = [handle, serviceHint ?? ""]

        let result: AppleScriptResult
        do {
            result = try await ExternalFocusTracker.shared.withExternalOperation {
                try await runner.execute(script: script, arguments: arguments, config: .json())
            }
        } catch let error as AppleScriptError {
            let details = MessagesToolError.safeLogDetails(from: error)
            let message = MessagesToolError.sanitizedMessage(from: error)
            Self.logger.error(
                "\(name, privacy: .public) failed: type=\(details.type, privacy: .public) app=\(details.app, privacy: .public) code=\(details.code, privacy: .public) message=\(message, privacy: .public)"
            )
            throw MessagesToolError.fromAppleScriptError(error)
        }

        Self.logger.info(
            "messages.open_chat AppleScript completed duration=\(String(format: "%.2f", result.duration), privacy: .public)s stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let data = try MessagesAppleScript.parseEnvelope(result)
        guard case .object(let dict) = data else {
            throw MessagesToolError.invalidResponse
        }

        let summary = Self.summary(handle: handle)
        Self.logger.info("Opened chat for handle length: \(handle.count, privacy: .public)")
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

    private static func isResolvableHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("@") {
            return true
        }
        let digits = trimmed.filter { $0.isNumber }
        return digits.count >= 7
    }

    private static func summary(handle: String) -> String {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHandle.isEmpty {
            return "Opened chat."
        }
        return "Opened chat with \(trimmedHandle)."
    }
}
