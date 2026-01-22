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
    case draftNotFound(String)
    case invalidArgument(String)
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Mail access denied. Please enable Automation access for Ora in System Settings > Privacy & Security > Automation."
        case .accountNotFound(let name):
            return "Mail account not found: \(name)"
        case .draftNotFound(let id):
            return "Draft not found: \(id)"
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
        if lowercased.hasPrefix("account not found:") {
            return .accountNotFound(
                String(message.dropFirst("account not found:".count)).trimmingCharacters(in: .whitespaces)
            )
        }
        if lowercased.hasPrefix("draft not found:") {
            return .draftNotFound(
                String(message.dropFirst("draft not found:".count)).trimmingCharacters(in: .whitespaces)
            )
        }
        if lowercased.hasPrefix("invalid argument:") {
            return .invalidArgument(
                String(message.dropFirst("invalid argument:".count)).trimmingCharacters(in: .whitespaces)
            )
        }
        return .scriptFailed(message)
    }
}
