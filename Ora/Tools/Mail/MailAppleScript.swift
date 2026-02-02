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

    on join_list(item_list, delimiter)
        set AppleScript's text item delimiters to delimiter
        set joined to item_list as string
        set AppleScript's text item delimiters to ""
        return joined
    end join_list

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

    private static let mailboxHelpers = """
    on resolve_account(accountName)
        tell application "Mail"
            if accountName is not "" then
                if exists account accountName then
                    return account accountName
                else
                    error "Account not found: " & accountName number 1001
                end if
            else
                set allAccounts to every account
                if (count of allAccounts) > 0 then
                    return item 1 of allAccounts
                else
                    error "No Mail account available" number 1001
                end if
            end if
        end tell
    end resolve_account

    on find_mailbox_by_name(accountRef, mailboxName)
        if mailboxName is "" then return missing value
        tell application "Mail"
            set matchBox to my search_mailboxes(mailboxes of accountRef, mailboxName)
        end tell
        return matchBox
    end find_mailbox_by_name

    on search_mailboxes(mailboxList, mailboxName)
        repeat with candidate in mailboxList
            try
                tell application "Mail"
                    if (name of candidate as string) is mailboxName then
                        return candidate
                    end if
                end tell
            end try
            try
                tell application "Mail"
                    set childBoxes to mailboxes of candidate
                end tell
                if (count of childBoxes) > 0 then
                    set childMatch to my search_mailboxes(childBoxes, mailboxName)
                    if childMatch is not missing value then
                        return childMatch
                    end if
                end if
            end try
        end repeat
        return missing value
    end search_mailboxes

    on collect_mailboxes(mailboxList, accountName)
        set collected to {}
        repeat with candidate in mailboxList
            set boxName to ""
            try
                tell application "Mail"
                    set boxName to name of candidate as string
                end tell
            end try
            if boxName is not "" then
                set end of collected to "{\\\"name\\\":\\\"" & my json_escape(boxName) & "\\\",\\\"account\\\":\\\"" & my json_escape(accountName) & "\\\"}"
            end if
            try
                tell application "Mail"
                    set childBoxes to mailboxes of candidate
                end tell
                if (count of childBoxes) > 0 then
                    set childItems to my collect_mailboxes(childBoxes, accountName)
                    set collected to collected & childItems
                end if
            end try
        end repeat
        return collected
    end collect_mailboxes
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

    /// Build script to search Mail messages by subject/sender.
    /// argv: [query, mailbox, account, limit]
    static func searchMessagesScript() -> String {
        return """
        \(Self.jsonHelpers)
        \(Self.mailboxHelpers)
        on run argv
            set queryText to item 1 of argv
            set mailboxName to ""
            if (count of argv) >= 2 then set mailboxName to item 2 of argv
            set accountName to ""
            if (count of argv) >= 3 then set accountName to item 3 of argv
            set limitCount to 5
            if (count of argv) >= 4 then
                try
                    set limitCount to (item 4 of argv) as integer
                on error
                    set limitCount to 5
                end try
            end if

            try
                tell application "Mail"
                    set jsonItems to {}
                    set accountsToSearch to {}
                    if accountName is not "" then
                        set targetAccount to my resolve_account(accountName)
                        set accountsToSearch to {targetAccount}
                    else
                        set accountsToSearch to every account
                        if (count of accountsToSearch) is 0 then
                            error "No Mail account available" number 1001
                        end if
                    end if

                    set mailboxFound to false

                    repeat with theAccount in accountsToSearch
                        if (count of jsonItems) >= limitCount then exit repeat
                        set accountTitle to ""
                        try
                            set accountTitle to name of theAccount as string
                        end try
                        if accountTitle is "" then set accountTitle to accountName

                        set targetMailbox to missing value
                        if mailboxName is not "" then
                            try
                                set targetMailbox to my find_mailbox_by_name(theAccount, mailboxName)
                            end try
                            if targetMailbox is not missing value then
                                set mailboxFound to true
                            end if
                        end if

                        if mailboxName is not "" and targetMailbox is missing value then
                            -- mailbox not in this account
                        else
                            set foundMessages to {}
                            if queryText is not "" then
                                try
                                    if targetMailbox is missing value then
                                        set foundMessages to (messages of theAccount whose subject contains queryText or sender contains queryText)
                                    else
                                        set foundMessages to (messages of targetMailbox whose subject contains queryText or sender contains queryText)
                                    end if
                                on error
                                    set foundMessages to {}
                                end try
                            end if

                            repeat with msg in foundMessages
                                if (count of jsonItems) >= limitCount then exit repeat
                                set msgSubject to ""
                                try
                                    set msgSubject to subject of msg as string
                                end try
                                set msgSender to ""
                                try
                                    set msgSender to sender of msg as string
                                end try
                                set msgDate to ""
                                try
                                    set msgDate to date received of msg as string
                                end try
                                set msgMailbox to ""
                                try
                                    set msgMailbox to name of mailbox of msg as string
                                end try
                                set msgId to ""
                                try
                                    set msgId to message id of msg as string
                                end try
                                set end of jsonItems to "{\\\"message_id\\\":\\\"" & my json_escape(msgId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(msgSubject) & "\\\",\\\"from\\\":\\\"" & my json_escape(msgSender) & "\\\",\\\"date\\\":\\\"" & my json_escape(msgDate) & "\\\",\\\"mailbox\\\":\\\"" & my json_escape(msgMailbox) & "\\\",\\\"account\\\":\\\"" & my json_escape(accountTitle) & "\\\"}"
                            end repeat
                        end if
                    end repeat

                    if mailboxName is not "" and mailboxFound is false then
                        error "Mailbox not found: " & mailboxName number 1002
                    end if

                    set jsonText to "[" & my join_list(jsonItems, ",") & "]"
                    set result to jsonText
                end tell
                return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
            on error errMsg number errNum
                return "{\\\"success\\\":false,\\\"error\\\":\\\"" & my json_escape(errMsg) & "\\\",\\\"code\\\":" & errNum & "}"
            end try
        end run
        """
    }

    /// Build script to fetch recent Mail messages (for fuzzy fallback).
    /// argv: [mailbox, account, limit]
    static func recentMessagesScript() -> String {
        return """
        \(Self.jsonHelpers)
        \(Self.mailboxHelpers)
        on run argv
            set mailboxName to ""
            if (count of argv) >= 1 then set mailboxName to item 1 of argv
            set accountName to ""
            if (count of argv) >= 2 then set accountName to item 2 of argv
            set limitCount to 100
            if (count of argv) >= 3 then
                try
                    set limitCount to (item 3 of argv) as integer
                on error
                    set limitCount to 100
                end try
            end if

            try
                tell application "Mail"
                    set jsonItems to {}
                    set accountsToSearch to {}
                    if accountName is not "" then
                        set targetAccount to my resolve_account(accountName)
                        set accountsToSearch to {targetAccount}
                    else
                        set accountsToSearch to every account
                        if (count of accountsToSearch) is 0 then
                            error "No Mail account available" number 1001
                        end if
                    end if

                    set mailboxFound to false

                    repeat with theAccount in accountsToSearch
                        if (count of jsonItems) >= limitCount then exit repeat
                        set accountTitle to ""
                        try
                            set accountTitle to name of theAccount as string
                        end try
                        if accountTitle is "" then set accountTitle to accountName

                        set targetMailbox to missing value
                        if mailboxName is not "" then
                            try
                                set targetMailbox to my find_mailbox_by_name(theAccount, mailboxName)
                            end try
                            if targetMailbox is not missing value then
                                set mailboxFound to true
                            end if
                        end if

                        if mailboxName is not "" and targetMailbox is missing value then
                            -- mailbox not in this account
                        else
                            if targetMailbox is missing value then
                                try
                                    set sourceMessages to messages of theAccount
                                on error
                                    set sourceMessages to {}
                                end try
                            else
                                try
                                    set sourceMessages to messages of targetMailbox
                                on error
                                    set sourceMessages to {}
                                end try
                            end if

                            repeat with msg in sourceMessages
                                if (count of jsonItems) >= limitCount then exit repeat
                                set msgSubject to ""
                                try
                                    set msgSubject to subject of msg as string
                                end try
                                set msgSender to ""
                                try
                                    set msgSender to sender of msg as string
                                end try
                                set msgDate to ""
                                try
                                    set msgDate to date received of msg as string
                                end try
                                set msgMailbox to ""
                                try
                                    set msgMailbox to name of mailbox of msg as string
                                end try
                                set msgId to ""
                                try
                                    set msgId to message id of msg as string
                                end try
                                set end of jsonItems to "{\\\"message_id\\\":\\\"" & my json_escape(msgId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(msgSubject) & "\\\",\\\"from\\\":\\\"" & my json_escape(msgSender) & "\\\",\\\"date\\\":\\\"" & my json_escape(msgDate) & "\\\",\\\"mailbox\\\":\\\"" & my json_escape(msgMailbox) & "\\\",\\\"account\\\":\\\"" & my json_escape(accountTitle) & "\\\"}"
                            end repeat
                        end if
                    end repeat

                    if mailboxName is not "" and mailboxFound is false then
                        error "Mailbox not found: " & mailboxName number 1002
                    end if

                    set jsonText to "[" & my join_list(jsonItems, ",") & "]"
                    set result to jsonText
                end tell
                return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
            on error errMsg number errNum
                return "{\\\"success\\\":false,\\\"error\\\":\\\"" & my json_escape(errMsg) & "\\\",\\\"code\\\":" & errNum & "}"
            end try
        end run
        """
    }

    /// Build script to open a Mail message by message-id.
    /// argv: [message_id]
    static func openMessageScript() -> String {
        return """
        \(Self.jsonHelpers)
        on run argv
            set messageId to item 1 of argv

            try
                tell application "Mail"
                    set foundMessages to (messages whose message id is messageId)
                    if (count of foundMessages) is 0 then
                        error "Message not found: " & messageId number 1003
                    end if

                    set targetMsg to item 1 of foundMessages
                    open targetMsg
                    activate

                    set msgSubject to ""
                    try
                        set msgSubject to subject of targetMsg as string
                    end try

                    set jsonText to "{\\\"message_id\\\":\\\"" & my json_escape(messageId) & "\\\",\\\"subject\\\":\\\"" & my json_escape(msgSubject) & "\\\"}"
                    set result to jsonText
                end tell
                return "{\\\"success\\\":true,\\\"data\\\":" & result & "}"
            on error errMsg number errNum
                return "{\\\"success\\\":false,\\\"error\\\":\\\"" & my json_escape(errMsg) & "\\\",\\\"code\\\":" & errNum & "}"
            end try
        end run
        """
    }

    /// Build script to list Mail mailboxes (with optional account filter).
    /// argv: [account]
    static func listMailboxesScript() -> String {
        return """
        \(Self.jsonHelpers)
        \(Self.mailboxHelpers)
        on run argv
            set accountName to ""
            if (count of argv) >= 1 then set accountName to item 1 of argv

            try
                tell application "Mail"
                    set jsonItems to {}
                    if accountName is not "" then
                        set targetAccount to my resolve_account(accountName)
                        set accountTitle to name of targetAccount as string
                        set jsonItems to my collect_mailboxes(mailboxes of targetAccount, accountTitle)
                    else
                        repeat with theAccount in accounts
                            set accountTitle to name of theAccount as string
                            set jsonItems to jsonItems & my collect_mailboxes(mailboxes of theAccount, accountTitle)
                        end repeat
                    end if

                    set jsonText to "[" & my join_list(jsonItems, ",") & "]"
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
