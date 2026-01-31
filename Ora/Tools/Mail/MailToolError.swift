//
//  MailToolError.swift
//  Ora
//
//  Errors for Mail tools
//

import Foundation

enum MailToolError: LocalizedError, Equatable {
    case permissionDenied
    case accountNotFound(String)
    case invalidArgument(String)
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Mail access denied. Please enable Automation access for Ora in System Settings > Privacy & Security > Automation."
        case .accountNotFound(let account):
            return "Mail account not found: \(account)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .scriptFailed(let reason):
            return "Mail operation failed: \(reason)"
        case .invalidResponse:
            return "Unexpected response from Mail."
        }
    }

    static func fromAppleScriptError(_ error: AppleScriptError) -> MailToolError {
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

    static func fromEnvelopeError(_ message: String) -> MailToolError {
        let lowercased = message.lowercased()
        if lowercased.contains("account not found") || lowercased.contains("no account") {
            return .accountNotFound(message)
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
