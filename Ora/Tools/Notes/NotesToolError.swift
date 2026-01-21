//
//  NotesToolError.swift
//  Ora
//
//  Errors for Notes tools
//

import Foundation

enum NotesToolError: LocalizedError, Equatable {
    case permissionDenied
    case accountNotFound(String)
    case folderNotFound(String)
    case noteNotFound(String)
    case invalidArgument(String)
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Notes access denied. Please enable Automation access for Ora in System Settings > Privacy & Security > Automation."
        case .accountNotFound(let name):
            return "Notes account not found: \(name)"
        case .folderNotFound(let name):
            return "Notes folder not found: \(name)"
        case .noteNotFound(let id):
            return "Note not found: \(id)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .scriptFailed(let reason):
            return "Notes operation failed: \(reason)"
        case .invalidResponse:
            return "Unexpected response from Notes."
        }
    }

    static func fromAppleScriptError(_ error: AppleScriptError) -> NotesToolError {
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

    static func fromEnvelopeError(_ message: String) -> NotesToolError {
        let lowercased = message.lowercased()
        if lowercased.hasPrefix("account not found:") {
            return .accountNotFound(String(message.dropFirst("account not found:".count)).trimmingCharacters(in: .whitespaces))
        }
        if lowercased.hasPrefix("folder not found:") {
            return .folderNotFound(String(message.dropFirst("folder not found:".count)).trimmingCharacters(in: .whitespaces))
        }
        if lowercased.hasPrefix("note not found:") {
            return .noteNotFound(String(message.dropFirst("note not found:".count)).trimmingCharacters(in: .whitespaces))
        }
        return .scriptFailed(message)
    }
}
