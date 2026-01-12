//
//  AppleScriptUtils.swift
//  Ora
//
//  JSON parsing and utility functions for AppleScript
//

import Foundation
import os.log

/// Standard JSON envelope for AppleScript results
///
/// Scripts should return output in this format:
/// ```
/// {"success": true, "data": {...}}
/// {"success": false, "error": "message", "code": -1}
/// ```
struct AppleScriptJSONEnvelope: Sendable {
    let success: Bool
    let data: JSONValue?
    let error: String?
    let code: Int?

    init(success: Bool, data: JSONValue?, error: String?, code: Int?) {
        self.success = success
        self.data = data
        self.error = error
        self.code = code
    }
}

/// Utility functions for AppleScript execution
enum AppleScriptUtils {
    private static let logger = Logger(subsystem: "com.ora.app", category: "AppleScriptUtils")

    /// Parse JSON from script output, handling the standard envelope format
    /// - Parameter output: Raw stdout from osascript
    /// - Returns: Parsed JSONValue, or nil if parsing fails
    static func parseJSONEnvelope(_ output: String) -> JSONValue? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        guard let data = trimmed.data(using: .utf8) else {
            self.logger.warning("Failed to convert output to UTF-8 data")
            return nil
        }

        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            return self.convertToJSONValue(jsonObject)
        } catch {
            self.logger.debug("Failed to parse JSON: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse and validate the standard envelope format
    /// - Parameter output: Raw stdout from osascript
    /// - Returns: The envelope, or nil if invalid
    static func parseEnvelope(_ output: String) -> AppleScriptJSONEnvelope? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }

        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let jsonObject = jsonObject else { return nil }

            guard let success = jsonObject["success"] as? Bool else { return nil }
            let error = jsonObject["error"] as? String
            let code = jsonObject["code"] as? Int

            var dataValue: JSONValue?
            if let dataObj = jsonObject["data"] {
                dataValue = self.convertToJSONValue(dataObj)
            }

            return AppleScriptJSONEnvelope(
                success: success,
                data: dataValue,
                error: error,
                code: code
            )
        } catch {
            self.logger.debug("Failed to parse envelope: \(error.localizedDescription)")
            return nil
        }
    }

    /// Convert a JSONSerialization result to JSONValue
    private static func convertToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // Check if it's a boolean
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.map { self.convertToJSONValue($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { self.convertToJSONValue($0) })
        case is NSNull:
            return .null
        default:
            return .null
        }
    }

    /// Build an AppleScript that returns JSON
    /// - Parameters:
    ///   - app: Target application name
    ///   - commands: AppleScript commands to execute within tell block
    ///   - wrapInJSON: Whether to wrap result in JSON envelope
    /// - Returns: Complete AppleScript source
    static func buildScript(
        for app: String,
        commands: String,
        wrapInJSON: Bool = true
    ) -> String {
        if wrapInJSON {
            return """
            try
                tell application "\(app)"
                    \(commands)
                end tell
                return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
            on error errMsg number errNum
                return "{\\\"success\\\":false,\\\"error\\\":\\\"" & errMsg & "\\\",\\\"code\\\":" & errNum & "}"
            end try
            """
        } else {
            return """
            tell application "\(app)"
                \(commands)
            end tell
            """
        }
    }

    /// Escape a string for safe inclusion in AppleScript
    /// - Parameter string: The string to escape
    /// - Returns: Escaped string safe for AppleScript
    static func escapeForAppleScript(_ string: String) -> String {
        var escaped = string
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return escaped
    }

    /// Convert AppleScript list/record output to JSON-compatible format
    /// - Parameter appleScriptOutput: Raw AppleScript output (e.g., "{name:\"foo\", id:123}")
    /// - Returns: JSON-compatible string, or nil if conversion fails
    static func convertRecordToJSON(_ appleScriptOutput: String) -> String? {
        // AppleScript records look like: {name:"John", age:30}
        // We need to convert to JSON: {"name":"John","age":30}

        var result = appleScriptOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it looks like an AppleScript record
        guard result.hasPrefix("{") && result.hasSuffix("}") else {
            return nil
        }

        // Replace AppleScript record syntax with JSON
        // key:value -> "key":value
        let pattern = #"(\w+):"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\"$1\":"
            )
        }

        // Validate it's now valid JSON
        if let data = result.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) {
            return result
        }

        return nil
    }

    /// Format a date for AppleScript
    /// - Parameter date: The date to format
    /// - Returns: AppleScript date string
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm:ss a"
        formatter.locale = Locale(identifier: "en_US")
        return "date \"\(formatter.string(from: date))\""
    }
}
