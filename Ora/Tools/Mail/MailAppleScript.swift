//
//  MailAppleScript.swift
//  Ora
//
//  AppleScript builders and parsing helpers for Mail tools.
//  All user input is passed via argv (no string interpolation).
//

import Foundation
import os

enum MailAppleScript {
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailAppleScript")
    private static let jsonHelpers = """
    on json_escape(theText)
        if theText is missing value then return ""
        set theText to theText as string
        set theText to my replace_chars(theText, "\\\\", "\\\\\\\\")
        set theText to my replace_chars(theText, "\\\"", "\\\\\\\"")
        set theText to my replace_chars(theText, return, "\\\\n")
        set theText to my replace_chars(theText, linefeed, "\\\\n")
        set theText to my replace_chars(theText, tab, "\\\\t")
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

    on split_recipients(theText)
        set AppleScript's text item delimiters to ","
        set theItems to every text item of theText
        set AppleScript's text item delimiters to ""
        set trimmedItems to {}
        repeat with anItem in theItems
            set trimmedItem to anItem as string
            repeat while trimmedItem starts with " "
                set trimmedItem to text 2 thru -1 of trimmedItem
            end repeat
            repeat while trimmedItem ends with " "
                set trimmedItem to text 1 thru -2 of trimmedItem
            end repeat
            if trimmedItem is not "" then
                set end of trimmedItems to trimmedItem
            end if
        end repeat
        return trimmedItems
    end split_recipients
    """

    // MARK: - Script Builders

    /// Build script to create a draft in Mail.
    /// argv: [to, subject, body, cc, bcc, account]
    static func createDraftScript() -> String {
        return """
        \(Self.jsonHelpers)
        on run argv
            set toField to item 1 of argv
            set subjectField to item 2 of argv
            set bodyField to item 3 of argv
            set ccField to ""
            if (count of argv) >= 4 then set ccField to item 4 of argv
            set bccField to ""
            if (count of argv) >= 5 then set bccField to item 5 of argv
            set accountName to ""
            if (count of argv) >= 6 then set accountName to item 6 of argv

            try
                tell application "Mail"
                    set newMsg to make new outgoing message with properties {subject:subjectField, content:bodyField, visible:false}

                    set toRecipients to my split_recipients(toField)
                    repeat with addr in toRecipients
                        make new to recipient at end of to recipients of newMsg with properties {address:addr}
                    end repeat

                    if ccField is not "" then
                        set ccRecipients to my split_recipients(ccField)
                        repeat with addr in ccRecipients
                            make new cc recipient at end of cc recipients of newMsg with properties {address:addr}
                        end repeat
                    end if

                    if bccField is not "" then
                        set bccRecipients to my split_recipients(bccField)
                        repeat with addr in bccRecipients
                            make new bcc recipient at end of bcc recipients of newMsg with properties {address:addr}
                        end repeat
                    end if

                    if accountName is not "" then
                        try
                            set targetAccount to account accountName
                            set sender of newMsg to email addresses of targetAccount as string
                        on error
                            error "Account not found: " & accountName number 1001
                        end try
                    end if

                    save newMsg

                    set draftId to id of newMsg as string
                    set draftSubject to subject of newMsg as string

                    set jsonText to "{\\\"draft_id\\\":\\\"" & my json_escape(draftId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(draftSubject) & "\\\"}"
                    set result to jsonText
                end tell
                return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
            on error errMsg number errNum
                return "{\\\"success\\\":false,\\\"error\\\":\\\"" & my json_escape(errMsg) & "\\\",\\\"code\\\":" & errNum & "}"
            end try
        end run
        """
    }

    /// Build script to send an email via Mail.
    /// argv: [to, subject, body, cc, bcc, account]
    static func sendScript() -> String {
        return """
        \(Self.jsonHelpers)
        on run argv
            set toField to item 1 of argv
            set subjectField to item 2 of argv
            set bodyField to item 3 of argv
            set ccField to ""
            if (count of argv) >= 4 then set ccField to item 4 of argv
            set bccField to ""
            if (count of argv) >= 5 then set bccField to item 5 of argv
            set accountName to ""
            if (count of argv) >= 6 then set accountName to item 6 of argv

            try
                tell application "Mail"
                    set newMsg to make new outgoing message with properties {subject:subjectField, content:bodyField, visible:false}

                    set toRecipients to my split_recipients(toField)
                    repeat with addr in toRecipients
                        make new to recipient at end of to recipients of newMsg with properties {address:addr}
                    end repeat

                    if ccField is not "" then
                        set ccRecipients to my split_recipients(ccField)
                        repeat with addr in ccRecipients
                            make new cc recipient at end of cc recipients of newMsg with properties {address:addr}
                        end repeat
                    end if

                    if bccField is not "" then
                        set bccRecipients to my split_recipients(bccField)
                        repeat with addr in bccRecipients
                            make new bcc recipient at end of bcc recipients of newMsg with properties {address:addr}
                        end repeat
                    end if

                    if accountName is not "" then
                        try
                            set targetAccount to account accountName
                            set sender of newMsg to email addresses of targetAccount as string
                        on error
                            error "Account not found: " & accountName number 1001
                        end try
                    end if

                    send newMsg

                    set msgSubject to subjectField

                    set jsonText to "{\\\"subject\\\":\\\"" & my json_escape(msgSubject) & "\\\",\\\"to\\\":\\\"" & my json_escape(toField) & "\\\"}"
                    set result to jsonText
                end tell
                return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
            on error errMsg number errNum
                return "{\\\"success\\\":false,\\\"error\\\":\\\"" & my json_escape(errMsg) & "\\\",\\\"code\\\":" & errNum & "}"
            end try
        end run
        """
    }

    /// Build script to open a draft window in Mail.
    /// argv: [draft_id]
    static func openDraftScript() -> String {
        return """
        \(Self.jsonHelpers)
        on run argv
            set draftId to item 1 of argv

            try
                tell application "Mail"
                    set targetMsg to missing value
                    repeat with msg in drafts mailbox's messages
                        if (id of msg as string) is draftId then
                            set targetMsg to msg
                            exit repeat
                        end if
                    end repeat

                    if targetMsg is missing value then
                        error "Draft not found: " & draftId number 1003
                    end if

                    set draftSubject to subject of targetMsg as string
                    open targetMsg
                    activate

                    set jsonText to "{\\\"draft_id\\\":\\\"" & my json_escape(draftId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(draftSubject) & "\\\"}"
                    set result to jsonText
                end tell
                return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
            on error errMsg number errNum
                return "{\\\"success\\\":false,\\\"error\\\":\\\"" & my json_escape(errMsg) & "\\\",\\\"code\\\":" & errNum & "}"
            end try
        end run
        """
    }

    // MARK: - Envelope Parsing

    static func parseEnvelope(_ result: AppleScriptResult) throws -> JSONValue {
        let output = result.stdout
        if let envelope = AppleScriptUtils.parseEnvelope(output) {
            return try Self.extractData(from: envelope, output: output)
        }

        let normalized = Self.normalizeEnvelopeOutput(output)
        if normalized != output, let envelope = AppleScriptUtils.parseEnvelope(normalized) {
            Self.logger.info("Normalized Mail response from escaped JSON.")
            return try Self.extractData(from: envelope, output: normalized)
        }

        let trimmed = Self.truncate(output)
        Self.logger.error("Failed to parse Mail response. stdout: \(trimmed, privacy: .private)")
        throw MailToolError.invalidResponse
    }

    private static func extractData(from envelope: AppleScriptJSONEnvelope, output: String) throws -> JSONValue {
        guard envelope.success else {
            let message = envelope.error ?? "Mail error"
            if let code = envelope.code, AppleScriptError.permissionErrorCodes.contains(code) {
                throw MailToolError.permissionDenied
            }

            let lowercased = message.lowercased()
            if lowercased.contains("not permitted") ||
                lowercased.contains("not authorized") ||
                lowercased.contains("permission") ||
                lowercased.contains("access denied") ||
                lowercased.contains("not allowed") {
                throw MailToolError.permissionDenied
            }

            throw MailToolError.fromEnvelopeError(message)
        }

        guard let data = envelope.data else {
            let trimmed = Self.truncate(output)
            Self.logger.error("Missing data in Mail response. stdout: \(trimmed, privacy: .private)")
            throw MailToolError.invalidResponse
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

    private static func truncate(_ value: String, limit: Int = 400) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit {
            return trimmed
        }
        let prefix = trimmed.prefix(limit)
        return "\(prefix)..."
    }
}
