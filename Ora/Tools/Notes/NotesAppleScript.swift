//
//  NotesAppleScript.swift
//  Ora
//
//  AppleScript builders and parsing helpers for Notes tools
//

import Foundation

enum NotesAppleScript {
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

        set jsonText to "{\\\\\\"note_id\\\\\\":\\\\\\"" & my json_escape(noteId) & "\\\\\\",\\\\\\"title\\\\\\":\\\\\\"" & my json_escape(noteTitle) & "\\\\\\",\\\\\\"folder\\\\\\":\\\\\\"" & my json_escape(folderTitle) & "\\\\\\",\\\\\\"account\\\\\\":\\\\\\"" & my json_escape(accountTitle) & "\\\\\\\"}"
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

            set end of jsonItems to "{\\\\\\"note_id\\\\\\":\\\\\\"" & my json_escape(noteId) & "\\\\\\",\\\\\\"title\\\\\\":\\\\\\"" & my json_escape(noteTitle) & "\\\\\\",\\\\\\"folder\\\\\\":\\\\\\"" & my json_escape(folderTitle) & "\\\\\\\"}"
        end repeat

        set itemsText to "[" & my join_list(jsonItems, ",") & "]"
        set jsonText to "{\\\\\\"items\\\\\\":" & itemsText & ",\\\\\\"total_count\\\\\\":" & totalCount & "}"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func openNoteScript(noteID: String) -> String {
        let noteIdValue = Self.escape(noteID)

        let commands = """
        set noteId to "\(noteIdValue)"
        if not (exists note id noteId) then
            error "Note not found: " & noteId number 1003
        end if

        set targetNote to note id noteId
        show targetNote
        activate

        set noteTitle to name of targetNote as string
        set jsonText to "{\\\\\\"note_id\\\\\\":\\\\\\"" & my json_escape(noteId) & "\\\\\\",\\\\\\"title\\\\\\":\\\\\\"" & my json_escape(noteTitle) & "\\\\\\\"}"
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
                set end of jsonItems to "{\\\\\\"name\\\\\\":\\\\\\"" & my json_escape(folderTitle) & "\\\\\\",\\\\\\"account\\\\\\":\\\\\\"" & my json_escape(accountTitle) & "\\\\\\\"}"
            end repeat
        end repeat

        set jsonText to "[" & my join_list(jsonItems, ",") & "]"
        set result to jsonText
        """

        return Self.buildScript(commands: commands)
    }

    static func parseEnvelope(_ result: AppleScriptResult) throws -> JSONValue {
        guard let envelope = AppleScriptUtils.parseEnvelope(result.stdout) else {
            throw NotesToolError.invalidResponse
        }

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
            throw NotesToolError.invalidResponse
        }

        return data
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
            return "{\\\\\\"success\\\\\\":true,\\\\\\"data\\\\\\":" & result & "}"
        on error errMsg number errNum
            return "{\\\\\\"success\\\\\\":false,\\\\\\"error\\\\\\":\\\\\\"" & errMsg & "\\\\\\",\\\\\\"code\\\\\\":" & errNum & "}"
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
}
