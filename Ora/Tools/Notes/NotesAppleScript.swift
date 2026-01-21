//
//  NotesAppleScript.swift
//  Ora
//
//  AppleScript builders and parsing helpers for Notes tools
//

import Foundation
import os

enum NotesAppleScript {
    private static let logger = Logger(subsystem: "com.ora.app", category: "NotesAppleScript")
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

    on html_escape(theText)
        if theText is missing value then return ""
        set theText to theText as string
        set theText to my replace_chars(theText, "&", "&amp;")
        set theText to my replace_chars(theText, "<", "&lt;")
        set theText to my replace_chars(theText, ">", "&gt;")
        set theText to my replace_chars(theText, "\\\"", "&quot;")
        return theText
    end html_escape

    on html_from_plain(theText)
        if theText is missing value then return "<div></div>"
        set theText to my html_escape(theText)
        set theText to my replace_chars(theText, return, "<br>")
        set theText to my replace_chars(theText, linefeed, "<br>")
        return "<div>" & theText & "</div>"
    end html_from_plain
    """

    static func createNoteScript(title: String?, body: String, folder: String?, account: String?) -> String {
        let accountName = Self.escapedOrEmpty(account)
        let folderName = Self.escapedOrEmpty(folder)
        let titleText = Self.escapedOrEmpty(title)
        let bodyText = Self.escape(body)

        let commands = """
        set accountName to "\(accountName)"
        set folderName to "\(folderName)"
        set titleText to "\(titleText)"
        set bodyText to "\(bodyText)"

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

        if targetAccount is missing value then
            error "Account not found: " & accountName number 1001
        end if

        set targetFolder to missing value
        if folderName is not "" then
            if exists folder folderName of targetAccount then
                set targetFolder to folder folderName of targetAccount
            else
                error "Folder not found: " & folderName number 1002
            end if
        else
            try
                set targetFolder to default folder of targetAccount
            on error
                set targetFolder to first folder of targetAccount
            end try
        end if

        if targetFolder is missing value then
            error "Folder not found: " & folderName number 1002
        end if

        if titleText is not "" then
            set newNote to make new note at targetFolder with properties {name:titleText, body:bodyText}
        else
            set newNote to make new note at targetFolder with properties {body:bodyText}
        end if

        set noteId to id of newNote as string
        set noteTitle to name of newNote as string
        set folderTitle to name of targetFolder as string
        set accountTitle to name of targetAccount as string

        set jsonText to "{\\\"note_id\\\":\\\"" & my json_escape(noteId) & "\\\",\\\"title\\\":\\\"" & my json_escape(noteTitle) & "\\\",\\\"folder\\\":\\\"" & my json_escape(folderTitle) & "\\\",\\\"account\\\":\\\"" & my json_escape(accountTitle) & "\\\"}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func searchNotesScript(query: String, limit: Int) -> String {
        let queryText = Self.escape(query)
        let limitValue = max(1, limit)

        let commands = """
        set queryText to "\(queryText)"
        set limitCount to \(limitValue)

        set foundNotes to every note whose name contains queryText
        set totalCount to count of foundNotes
        set jsonItems to {}

        repeat with theNote in foundNotes
            if (count of jsonItems) >= limitCount then exit repeat

            set noteId to id of theNote as string
            set noteTitle to name of theNote as string
            set folderTitle to ""

            try
                set folderItem to container of theNote
                set folderTitle to name of folderItem as string
            end try

            set end of jsonItems to "{\\\"note_id\\\":\\\"" & my json_escape(noteId) & "\\\",\\\"title\\\":\\\"" & my json_escape(noteTitle) & "\\\",\\\"folder\\\":\\\"" & my json_escape(folderTitle) & "\\\"}"
        end repeat

        set itemsText to "[" & my join_list(jsonItems, ",") & "]"
        set jsonText to "{\\\"items\\\":" & itemsText & ",\\\"total_count\\\":" & totalCount & "}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func openNoteScript(noteID: String) -> String {
        let noteIdValue = Self.escape(Self.normalizeNoteID(noteID))

        let commands = """
        set noteId to "\(noteIdValue)"
        if not (exists note id noteId) then
            error "Note not found: " & noteId number 1003
        end if

        set targetNote to note id noteId
        show targetNote
        activate

        set noteTitle to name of targetNote as string
        set jsonText to "{\\\"note_id\\\":\\\"" & my json_escape(noteId) & "\\\",\\\"title\\\":\\\"" & my json_escape(noteTitle) & "\\\"}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func readNoteScript(noteID: String, maxChars: Int) -> String {
        let noteIdValue = Self.escape(Self.normalizeNoteID(noteID))
        let maxValue = max(1, maxChars)

        let commands = """
        set noteId to "\(noteIdValue)"
        set maxChars to \(maxValue)

        if not (exists note id noteId) then
            error "Note not found: " & noteId number 1003
        end if

        set targetNote to note id noteId
        set noteTitle to name of targetNote as string
        set noteBody to plaintext of targetNote as string
        set totalChars to length of noteBody
        set truncated to false
        set returnedBody to noteBody

        if totalChars > maxChars then
            set returnedBody to text 1 thru maxChars of noteBody
            set truncated to true
        end if

        set returnedChars to length of returnedBody
        set remainingChars to totalChars - returnedChars

        set jsonText to "{\\\"note_id\\\":\\\"" & my json_escape(noteId) & "\\\",\\\"title\\\":\\\"" & my json_escape(noteTitle) & "\\\",\\\"body\\\":\\\"" & my json_escape(returnedBody) & "\\\",\\\"total_chars\\\":" & totalChars & ",\\\"returned_chars\\\":" & returnedChars & ",\\\"remaining_chars\\\":" & remainingChars & ",\\\"truncated\\\":" & truncated & "}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func editNoteScript(noteID: String, text: String, mode: String) -> String {
        let noteIdValue = Self.escape(Self.normalizeNoteID(noteID))
        let textValue = Self.escape(text)
        let modeValue = Self.escape(mode)

        let commands = """
        set noteId to "\(noteIdValue)"
        set editMode to "\(modeValue)"
        set newText to "\(textValue)"

        if not (exists note id noteId) then
            error "Note not found: " & noteId number 1003
        end if

        set targetNote to note id noteId
        set noteTitle to name of targetNote as string
        set htmlText to my html_from_plain(newText)
        set newBody to htmlText

        if editMode is "append" then
            set existingBody to body of targetNote as string
            if existingBody is not "" then
                set newBody to existingBody & "<div><br></div>" & htmlText
            end if
        else if editMode is "replace" then
            set newBody to htmlText
        else
            error "Invalid edit mode: " & editMode number 1004
        end if

        set body of targetNote to newBody

        set jsonText to "{\\\"note_id\\\":\\\"" & my json_escape(noteId) & "\\\",\\\"title\\\":\\\"" & my json_escape(noteTitle) & "\\\",\\\"mode\\\":\\\"" & my json_escape(editMode) & "\\\"}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func listFoldersScript(account: String?) -> String {
        let accountName = Self.escapedOrEmpty(account)

        let commands = """
        set accountName to "\(accountName)"
        set jsonItems to {}

        if accountName is not "" then
            if exists account accountName then
                set accountsList to {account accountName}
            else
                error "Account not found: " & accountName number 1001
            end if
        else
            set accountsList to accounts
        end if

        repeat with theAccount in accountsList
            set accountTitle to name of theAccount as string
            repeat with theFolder in folders of theAccount
                set folderTitle to name of theFolder as string
                set end of jsonItems to "{\\\"name\\\":\\\"" & my json_escape(folderTitle) & "\\\",\\\"account\\\":\\\"" & my json_escape(accountTitle) & "\\\"}"
            end repeat
        end repeat

        set jsonText to "[" & my join_list(jsonItems, ",") & "]"
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
            Self.logger.info("Normalized Notes response from escaped JSON.")
            return try Self.extractData(from: envelope, output: normalized)
        }

        let trimmed = Self.truncate(output)
        Self.logger.error("Failed to parse Notes response. stdout: \(trimmed, privacy: .private)")
        throw NotesToolError.invalidResponse
    }

    private static func extractData(from envelope: AppleScriptJSONEnvelope, output: String) throws -> JSONValue {
        guard envelope.success else {
            let message = envelope.error ?? "Notes error"
            if let code = envelope.code, AppleScriptError.permissionErrorCodes.contains(code) {
                throw NotesToolError.permissionDenied
            }

            let lowercased = message.lowercased()
            if lowercased.contains("not permitted") ||
                lowercased.contains("not authorized") ||
                lowercased.contains("permission") ||
                lowercased.contains("access denied") ||
                lowercased.contains("not allowed") {
                throw NotesToolError.permissionDenied
            }

            throw NotesToolError.fromEnvelopeError(message)
        }

        guard let data = envelope.data else {
            let trimmed = Self.truncate(output)
            Self.logger.error("Missing data in Notes response. stdout: \(trimmed, privacy: .private)")
            throw NotesToolError.invalidResponse
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
            tell application "Notes"
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

    private static func normalizeNoteID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("x-coredata:///") {
            return trimmed.replacingOccurrences(of: "x-coredata:///", with: "x-coredata://")
        }
        return trimmed
    }

    private static func truncate(_ value: String, limit: Int = 400) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit {
            return trimmed
        }
        let prefix = trimmed.prefix(limit)
        return "\(prefix)…"
    }
}
