//
//  MessagesAppleScript.swift
//  Ora
//
//  AppleScript builders and parsing helpers for Messages tools
//

import Foundation
import os

enum MessagesAppleScript {
    private static let logger = Logger(subsystem: "com.ora.app", category: "MessagesAppleScript")
    private static let jsonHelpers = """
    on json_escape(theText)
        if theText is missing value then return ""
        set theText to theText as string
        set theText to my replace_chars(theText, "\\", "\\\\")
        set theText to my replace_chars(theText, "\\\"", "\\\\\"")
        set theText to my replace_chars(theText, return, "\\n")
        set theText to my replace_chars(theText, linefeed, "\\n")
        set theText to my replace_chars(theText, tab, "\\t")
        return theText
    end json_escape

    on replace_chars(this_text, search_string, replacement_string)
        set AppleScript's text item delimiters to search_string
        set the item_list to every text item of this_text
        set AppleScript's text item delimiters to replacement_string
        set this_text to the item_list as string
        set AppleScript's text item delimiters to ""
        return this_text
    end replace_chars
    """

    static func sendMessageScript(handle: String, message: String, service: String?) -> String {
        let handleText = Self.escape(handle)
        let messageText = Self.escape(message)
        let serviceText = Self.escapedOrEmpty(service)

        let commands = """
        set targetHandle to "\(handleText)"
        set messageText to "\(messageText)"
        set serviceHint to "\(serviceText)"

        set targetAccount to missing value
        if serviceHint is not "" then
            repeat with candidate in accounts
                try
                    set candidateService to service type of candidate as string
                    if candidateService is serviceHint then
                        set targetAccount to candidate
                        exit repeat
                    end if
                end try
            end repeat
        end if

        if targetAccount is missing value then
            repeat with candidate in accounts
                try
                    set candidateService to service type of candidate as string
                    if candidateService is "iMessage" then
                        set targetAccount to candidate
                        exit repeat
                    end if
                end try
            end repeat
        end if

        if targetAccount is missing value then
            if (count of accounts) > 0 then
                set targetAccount to first account
            else
                error "No Messages account available" number 1001
            end if
        end if

        set targetParticipant to participant targetHandle of targetAccount
        send messageText to targetParticipant

        set serviceName to ""
        try
            set serviceName to service type of targetAccount as string
        end try

        set jsonText to "{\\\"handle\\\":\\\"" & my json_escape(targetHandle) & "\\\",\\\"message\\\":\\\"" & my json_escape(messageText) & "\\\",\\\"service\\\":\\\"" & my json_escape(serviceName) & "\\\"}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func openChatScript(handle: String, service: String?) -> String {
        let handleText = Self.escape(handle)
        let serviceText = Self.escapedOrEmpty(service)

        let commands = """
        set targetHandle to "\(handleText)"
        set serviceHint to "\(serviceText)"

        set targetAccount to missing value
        if serviceHint is not "" then
            repeat with candidate in accounts
                try
                    set candidateService to service type of candidate as string
                    if candidateService is serviceHint then
                        set targetAccount to candidate
                        exit repeat
                    end if
                end try
            end repeat
        end if

        if targetAccount is missing value then
            repeat with candidate in accounts
                try
                    set candidateService to service type of candidate as string
                    if candidateService is "iMessage" then
                        set targetAccount to candidate
                        exit repeat
                    end if
                end try
            end repeat
        end if

        if targetAccount is missing value then
            if (count of accounts) > 0 then
                set targetAccount to first account
            else
                error "No Messages account available" number 1001
            end if
        end if

        set targetParticipant to participant targetHandle of targetAccount
        set targetChat to make new chat with properties {participants:{targetParticipant}}
        activate

        set chatId to ""
        try
            set chatId to id of targetChat as string
        end try

        set serviceName to ""
        try
            set serviceName to service type of targetAccount as string
        end try

        set jsonText to "{\\\"handle\\\":\\\"" & my json_escape(targetHandle) & "\\\",\\\"chat_id\\\":\\\"" & my json_escape(chatId) & "\\\",\\\"service\\\":\\\"" & my json_escape(serviceName) & "\\\"}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func parseEnvelope(_ result: AppleScriptResult) throws -> JSONValue {
        let output = result.stdout
        if let envelope = AppleScriptUtils.parseEnvelope(output) {
            return try Self.extractData(from: envelope, output: output)
        }

        let normalized = Self.normalizeEnvelopeOutput(output)
        if normalized != output, let envelope = AppleScriptUtils.parseEnvelope(normalized) {
            Self.logger.info("Normalized Messages response from escaped JSON.")
            return try Self.extractData(from: envelope, output: normalized)
        }

        let trimmed = Self.truncate(output)
        Self.logger.error("Failed to parse Messages response. stdout: \(trimmed, privacy: .private)")
        throw MessagesToolError.invalidResponse
    }

    private static func extractData(from envelope: AppleScriptJSONEnvelope, output: String) throws -> JSONValue {
        guard envelope.success else {
            let message = envelope.error ?? "Messages error"
            if let code = envelope.code, AppleScriptError.permissionErrorCodes.contains(code) {
                throw MessagesToolError.permissionDenied
            }

            let lowercased = message.lowercased()
            if lowercased.contains("not permitted") ||
                lowercased.contains("not authorized") ||
                lowercased.contains("permission") ||
                lowercased.contains("access denied") ||
                lowercased.contains("not allowed") {
                throw MessagesToolError.permissionDenied
            }

            throw MessagesToolError.fromEnvelopeError(message)
        }

        guard let data = envelope.data else {
            let trimmed = Self.truncate(output)
            Self.logger.error("Missing data in Messages response. stdout: \(trimmed, privacy: .private)")
            throw MessagesToolError.invalidResponse
        }

        return data
    }

    private static func normalizeEnvelopeOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
           let data = trimmed.data(using: .utf8),
           let unescaped = try? JSONSerialization.jsonObject(with: data) as? String {
            return unescaped
        }

        guard trimmed.contains("\\\"success\\\"") else {
            return trimmed
        }

        var unescaped = trimmed
        unescaped = unescaped.replacingOccurrences(of: "\\\"", with: "\"")
        unescaped = unescaped.replacingOccurrences(of: "\\n", with: "\n")
        unescaped = unescaped.replacingOccurrences(of: "\\r", with: "\r")
        unescaped = unescaped.replacingOccurrences(of: "\\t", with: "\t")
        unescaped = unescaped.replacingOccurrences(of: "\\\\", with: "\\")
        return unescaped
    }

    // MARK: - Private

    private static func buildScript(commands: String) -> String {
        let indented = Self.indent(commands, spaces: 8)
        return """
        \(Self.jsonHelpers)
        try
            tell application "Messages"
        \(indented)
            end tell
            return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
        on error errMsg number errNum
            return "{\\\"success\\\":false,\\\"error\\\":\\\"" & my json_escape(errMsg) & "\\\",\\\"code\\\":" & errNum & "}"
        end try
        """
    }

    private static func indent(_ text: String, spaces: Int) -> String {
        let padding = String(repeating: " ", count: spaces)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { padding + $0 }
            .joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        AppleScriptUtils.escapeForAppleScript(value)
    }

    private static func escapedOrEmpty(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else {
            return ""
        }
        return Self.escape(value)
    }

    private static func truncate(_ value: String, limit: Int = 400) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit {
            return trimmed
        }
        let prefix = trimmed.prefix(limit)
        return "\(prefix)..."
    }
}
