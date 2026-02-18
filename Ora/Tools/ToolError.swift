import Foundation

protocol ToolError: LocalizedError {
    var userFacingMessage: String { get }
}

extension ToolError {
    var userFacingMessage: String {
        return self.errorDescription ?? "An unknown tool error occurred."
    }
}

extension CalendarToolError: ToolError {}
extension ContactsToolError: ToolError {}
extension MailToolError: ToolError {}
extension MessagesToolError: ToolError {}
extension NotesToolError: ToolError {}
extension RemindersToolError: ToolError {}
extension SystemToolError: ToolError {}
