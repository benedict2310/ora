//
//  AppleScriptError.swift
//  Ora
//
//  Error types for AppleScript execution
//

import Foundation

/// Categorized AppleScript execution errors
enum AppleScriptError: LocalizedError, Sendable {
    /// Script execution permission denied by system
    case permissionDenied(app: String?, errorNumber: Int?, rawMessage: String)

    /// Script execution timed out
    case timeout(seconds: TimeInterval)

    /// Script failed to execute
    case executionFailed(errorNumber: Int?, rawMessage: String)

    /// Script returned invalid or unparseable output
    case invalidOutput(rawOutput: String)

    /// Process could not be started
    case processStartFailed(reason: String)

    /// Script was cancelled
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let app, _, _):
            if let app = app {
                return "Ora needs permission to control \(app). Please enable Automation access in System Settings > Privacy & Security > Automation."
            }
            return "Automation permission denied. Please enable Automation access in System Settings > Privacy & Security > Automation."

        case .timeout(let seconds):
            return "Script timed out after \(Int(seconds)) seconds."

        case .executionFailed(_, let rawMessage):
            return "AppleScript execution failed: \(rawMessage)"

        case .invalidOutput(let rawOutput):
            let truncated = rawOutput.prefix(100)
            return "Invalid script output: \(truncated)"

        case .processStartFailed(let reason):
            return "Failed to start script process: \(reason)"

        case .cancelled:
            return "Script execution was cancelled."
        }
    }

    /// Debug metadata for logging
    var debugInfo: [String: String] {
        var info: [String: String] = ["type": errorType]

        switch self {
        case .permissionDenied(let app, let errorNumber, let rawMessage):
            if let app = app { info["app"] = app }
            if let num = errorNumber { info["errorNumber"] = String(num) }
            info["rawMessage"] = rawMessage

        case .timeout(let seconds):
            info["timeoutSeconds"] = String(Int(seconds))

        case .executionFailed(let errorNumber, let rawMessage):
            if let num = errorNumber { info["errorNumber"] = String(num) }
            info["rawMessage"] = rawMessage

        case .invalidOutput(let rawOutput):
            info["rawOutput"] = String(rawOutput.prefix(500))

        case .processStartFailed(let reason):
            info["reason"] = reason

        case .cancelled:
            break
        }

        return info
    }

    /// Error type string for categorization
    var errorType: String {
        switch self {
        case .permissionDenied: return "permission_denied"
        case .timeout: return "timeout"
        case .executionFailed: return "execution_failed"
        case .invalidOutput: return "invalid_output"
        case .processStartFailed: return "process_start_failed"
        case .cancelled: return "cancelled"
        }
    }
}

// MARK: - Error Parsing

extension AppleScriptError {
    /// Known Apple Event error codes for permission issues
    static let permissionErrorCodes: Set<Int> = [
        -1744,  // errAEEventWouldRequireUserConsent
        -1743,  // errAEEventNotPermitted
        -10004, // kAENotPermitted
        -600,   // procNotFound (can indicate permission issue)
        -10006, // kAENotPermitted (alternative)
    ]

    /// Parse an error from osascript stderr output
    static func parse(stderr: String, errorCode: Int32? = nil) -> AppleScriptError {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract error number from stderr
        // Format: "execution error: ... (-1744)" or "error ... number -1744"
        var extractedErrorNumber: Int?

        if let match = trimmed.range(of: #"\((-?\d+)\)"#, options: .regularExpression) {
            let numStr = trimmed[match].dropFirst().dropLast()
            extractedErrorNumber = Int(numStr)
        } else if let match = trimmed.range(of: #"number (-?\d+)"#, options: .regularExpression) {
            let numStr = trimmed[match].dropFirst(7)
            extractedErrorNumber = Int(numStr)
        }

        // Use extracted error number or fall back to exit code
        let effectiveErrorNumber = extractedErrorNumber ?? (errorCode.map { Int($0) })

        // Check for permission errors
        if let errorNum = effectiveErrorNumber, Self.permissionErrorCodes.contains(errorNum) {
            let app = Self.extractAppName(from: trimmed)
            return .permissionDenied(app: app, errorNumber: errorNum, rawMessage: trimmed)
        }

        // Check for permission-related keywords
        let lowercased = trimmed.lowercased()
        if lowercased.contains("not permitted") ||
           lowercased.contains("permission") ||
           lowercased.contains("not allowed") ||
           lowercased.contains("access denied") ||
           lowercased.contains("requires user consent") {
            let app = Self.extractAppName(from: trimmed)
            return .permissionDenied(app: app, errorNumber: effectiveErrorNumber, rawMessage: trimmed)
        }

        // Generic execution failure
        return .executionFailed(errorNumber: effectiveErrorNumber, rawMessage: trimmed)
    }

    /// Extract app name from error message
    private static func extractAppName(from message: String) -> String? {
        // Common patterns:
        // "Application "Notes" got an error..."
        // "Can't get application "Mail"..."
        // "tell application "Reminders"..."

        let patterns = [
            #"[Aa]pplication \"([^\"]+)\""#,
            #"tell application \"([^\"]+)\""#,
            #"\"([^\"]+)\" is not allowed"#,
        ]

        for pattern in patterns {
            if let match = message.range(of: pattern, options: .regularExpression),
               let nameMatch = message.range(of: #"\"([^\"]+)\""#, options: .regularExpression, range: match) {
                let quoted = message[nameMatch]
                return String(quoted.dropFirst().dropLast())
            }
        }

        return nil
    }
}
