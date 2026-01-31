//
//  MessagesToolError.swift
//  Ora
//
//  Errors for Messages tools
//

import Foundation

enum MessagesToolError: LocalizedError, Equatable {
    case permissionDenied
    case accountUnavailable
    case invalidHandle(String)
    case invalidArgument(String)
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Messages access denied. Please enable Automation access for Ora in System Settings > Privacy & Security > Automation."
        case .accountUnavailable:
            return "No Messages account is available. Please sign in to Messages and try again."
        case .invalidHandle(let handle):
            return "Invalid message recipient: \(handle)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .scriptFailed(let reason):
            return "Messages operation failed: \(reason)"
        case .invalidResponse:
            return "Unexpected response from Messages."
        }
    }

    static func fromAppleScriptError(_ error: AppleScriptError) -> MessagesToolError {
        switch error {
        case .permissionDenied:
            return .permissionDenied
        case .timeout(let seconds):
            return .scriptFailed("Script timed out after \(Int(seconds)) seconds.")
        case .executionFailed(_, let rawMessage):
            return .scriptFailed(rawMessage)
        case .invalidOutput:
            return .invalidResponse
        case .processStartFailed(let reason):
            return .scriptFailed(reason)
        case .cancelled:
            return .scriptFailed("Script execution was cancelled.")
        }
    }

    static func fromEnvelopeError(_ message: String) -> MessagesToolError {
        let lowercased = message.lowercased()
        if lowercased.contains("no messages account") {
            return .accountUnavailable
        }
        if lowercased.contains("participant") || lowercased.contains("buddy") || lowercased.contains("handle") {
            return .invalidHandle(message)
        }
        if lowercased.contains("invalid argument") {
            return .invalidArgument(message)
        }
        return .scriptFailed(message)
    }

    static func safeLogDetails(from error: AppleScriptError) -> (type: String, app: String, code: String) {
        let info = error.debugInfo
        let app = info["app"] ?? "unknown"
        let code = info["errorNumber"] ?? info["timeoutSeconds"] ?? "none"
        return (error.errorType, app, code)
    }

    static func sanitizedMessage(from error: AppleScriptError) -> String {
        let info = error.debugInfo
        let raw = info["rawMessage"] ?? info["reason"] ?? info["rawOutput"] ?? "unknown"
        var sanitized = raw
        sanitized = sanitized.replacingOccurrences(
            of: #""[^"]*""#,
            with: "\"<redacted>\"",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            with: "<redacted>",
            options: [.regularExpression, .caseInsensitive]
        )
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200)) + "..."
        }
        return sanitized
    }
}
