//
//  MailAppleScript.swift
//  Ora
//
//  AppleScript builders and parsing helpers for Mail tools
//

import Foundation
import os

enum MailAppleScript {
    private static let logger = Logger(subsystem: "com.ora.app", category: "MailAppleScript")
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

    on join_list(item_list, delimiter)
        set AppleScript's text item delimiters to delimiter
        set joined to item_list as string
        set AppleScript's text item delimiters to ""
        return joined
    end join_list

    on trim_text(theText)
        if theText is missing value then return ""
        set trimmedText to theText as string
        repeat while trimmedText is not "" and (character 1 of trimmedText is " " or character 1 of trimmedText is tab)
            set trimmedText to text 2 thru -1 of trimmedText
        end repeat
        repeat while trimmedText is not "" and (character -1 of trimmedText is " " or character -1 of trimmedText is tab)
            set trimmedText to text 1 thru -2 of trimmedText
        end repeat
        return trimmedText
    end trim_text

    on split_recipients(theText)
        if theText is missing value then return {}
        set cleaned to theText as string
        set cleaned to my replace_chars(cleaned, ";", ",")
        set cleaned to my replace_chars(cleaned, return, ",")
        set cleaned to my replace_chars(cleaned, linefeed, ",")
        set AppleScript's text item delimiters to ","
        set items to text items of cleaned
        set AppleScript's text item delimiters to ""
        set recipients to {}
        repeat with itemText in items
            set trimmed to my trim_text(itemText)
            if trimmed is not "" then set end of recipients to trimmed
        end repeat
        return recipients
    end split_recipients
    """

    static func createDraftScript(to: String, cc: String?, bcc: String?, subject: String, body: String, account: String?) -> String {
        let toText = Self.escape(to)
        let ccText = Self.escapedOrEmpty(cc)
        let bccText = Self.escapedOrEmpty(bcc)
        let subjectText = Self.escape(subject)
        let bodyText = Self.escape(body)
        let accountName = Self.escapedOrEmpty(account)

        let commands = """
        set toText to "\(toText)"
        set ccText to "\(ccText)"
        set bccText to "\(bccText)"
        set subjectText to "\(subjectText)"
        set bodyText to "\(bodyText)"
        set accountName to "\(accountName)"

        set targetAccount to missing value
        if accountName is not "" then
            if exists account accountName then
                set targetAccount to account accountName
            else
                error "Account not found: " & accountName number 1001
            end if
        else
            try
                set targetAccount to default account
            on error
                set targetAccount to first account
            end try
        end if

        set senderAddress to ""
        if targetAccount is not missing value then
            try
                set senderList to email addresses of targetAccount
                if (count of senderList) > 0 then
                    set senderAddress to item 1 of senderList as string
                end if
            end try
        end if

        set newMessage to make new outgoing message with properties {subject:subjectText, content:bodyText, visible:false}
        if senderAddress is not "" then
            set sender of newMessage to senderAddress
        end if

        set toList to my split_recipients(toText)
        repeat with address in toList
            make new to recipient at end of to recipients of newMessage with properties {address:address}
        end repeat

        set ccList to my split_recipients(ccText)
        repeat with address in ccList
            make new cc recipient at end of cc recipients of newMessage with properties {address:address}
        end repeat

        set bccList to my split_recipients(bccText)
        repeat with address in bccList
            make new bcc recipient at end of bcc recipients of newMessage with properties {address:address}
        end repeat

        save newMessage

        set messageId to id of newMessage as string
        set accountTitle to ""
        if targetAccount is not missing value then
            set accountTitle to name of targetAccount as string
        end if

        set toItems to {}
        repeat with address in toList
            set end of toItems to "\\\"" & my json_escape(address) & "\\\""
        end repeat
        set toJson to "[" & my join_list(toItems, ",") & "]"

        set ccItems to {}
        repeat with address in ccList
            set end of ccItems to "\\\"" & my json_escape(address) & "\\\""
        end repeat
        set ccJson to "[" & my join_list(ccItems, ",") & "]"

        set bccItems to {}
        repeat with address in bccList
            set end of bccItems to "\\\"" & my json_escape(address) & "\\\""
        end repeat
        set bccJson to "[" & my join_list(bccItems, ",") & "]"

        set jsonText to "{\\\"draft_id\\\":\\\"" & my json_escape(messageId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(subjectText) & "\\\",\\\"to\\\":" & toJson & ",\\\"cc\\\":" & ccJson & ",\\\"bcc\\\":" & bccJson & ",\\\"account\\\":\\\"" & my json_escape(accountTitle) & "\\\"}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func sendEmailScript(to: String, subject: String, body: String) -> String {
        let toText = Self.escape(to)
        let subjectText = Self.escape(subject)
        let bodyText = Self.escape(body)

        let commands = """
        set toText to "\(toText)"
        set subjectText to "\(subjectText)"
        set bodyText to "\(bodyText)"

        set targetAccount to missing value
        try
            set targetAccount to default account
        on error
            set targetAccount to first account
        end try

        set senderAddress to ""
        if targetAccount is not missing value then
            try
                set senderList to email addresses of targetAccount
                if (count of senderList) > 0 then
                    set senderAddress to item 1 of senderList as string
                end if
            end try
        end if

        set newMessage to make new outgoing message with properties {subject:subjectText, content:bodyText, visible:false}
        if senderAddress is not "" then
            set sender of newMessage to senderAddress
        end if

        set toList to my split_recipients(toText)
        repeat with address in toList
            make new to recipient at end of to recipients of newMessage with properties {address:address}
        end repeat

        send newMessage

        set messageId to id of newMessage as string

        set toItems to {}
        repeat with address in toList
            set end of toItems to "\\\"" & my json_escape(address) & "\\\""
        end repeat
        set toJson to "[" & my join_list(toItems, ",") & "]"

        set jsonText to "{\\\"message_id\\\":\\\"" & my json_escape(messageId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(subjectText) & "\\\",\\\"to\\\":" & toJson & ",\\\"sent\\\":true}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func openDraftScript(draftID: String) -> String {
        let draftIdValue = Self.escape(draftID)

        let commands = """
        set draftId to "\(draftIdValue)"
        set draftIdValue to draftId
        try
            set draftIdValue to draftId as integer
        end try
        set targetMessage to missing value

        repeat with theAccount in accounts
            try
                set draftsBox to drafts mailbox of theAccount
                set targetMessage to first message of draftsBox whose id is draftIdValue
                exit repeat
            end try
        end repeat

        if targetMessage is missing value then
            error "Draft not found: " & draftId number 1003
        end if

        open targetMessage
        activate

        set messageId to id of targetMessage as string
        set subjectText to subject of targetMessage as string

        set jsonText to "{\\\"draft_id\\\":\\\"" & my json_escape(messageId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(subjectText) & "\\\"}"
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

    private static func buildScript(commands: String) -> String {
        let indented = Self.indent(commands, spaces: 8)
        return """
        \(Self.jsonHelpers)
        try
            tell application id "com.apple.mail"
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
