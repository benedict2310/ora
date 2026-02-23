//
//  ToolRegistry.swift
//  Ora
//
//  Central registry for all available tools
//

import Foundation
import os

/// Central registry of available tools
actor ToolRegistry {
    
    // MARK: - Singleton
    
    static let shared = ToolRegistry()
    
    // MARK: - Properties
    
    private let logger = Logger.ora(category: "ToolRegistry")
    private var tools: [String: any Tool] = [:]
    
    // MARK: - Initialization
    
    private init() {}
    
    /// Create a test instance (not a singleton)
    static func makeTestInstance() -> ToolRegistry {
        return ToolRegistry()
    }
    
    // MARK: - Public API
    
    /// Register a tool
    func register(_ tool: any Tool) {
        tools[tool.name] = tool
        logger.debug("Registered tool: \(tool.name)")
    }
    
    /// Get a tool by name
    func tool(named name: String) -> (any Tool)? {
        tools[name]
    }
    
    /// Get all registered tools
    func allTools() -> [any Tool] {
        Array(tools.values)
    }
    
    /// Get tool schemas for system prompt
    func schemas() -> [ToolSchema] {
        tools.values.map { $0.schema }
    }
    
    /// Register all default tools
    func registerDefaultTools() {
        // Calendar tools
        register(CalendarQueryTool())
        register(CalendarFindSlotsTool())
        register(CalendarCreateEventTool())
        register(CalendarEditEventTool())
        register(CalendarDeleteEventTool())

        // Reminders tools
        register(RemindersListTool())
        register(RemindersCreateTool())
        register(RemindersCompleteTool())
        register(RemindersEditTool())

        // Contacts tools
        register(ContactsSearchTool())

        // Skills tools
        register(SkillsListTool())
        register(SkillsLoadTool())
        register(SkillsReadTool())

        // Notes tools
        register(NotesCreateTool())
        register(NotesSearchTool())
        register(NotesRecentTool())
        register(NotesOpenTool())
        register(NotesReadTool())
        register(NotesEditTool())
        register(NotesListFoldersTool())

        // Messages tools
        register(MessagesSendTool())
        register(MessagesOpenChatTool())

        // Mail tools
        register(MailCreateDraftTool())
        register(MailSendTool())
        register(MailOpenDraftTool())
        register(MailSearchTool())
        register(MailRecentTool())
        register(MailOpenMessageTool())
        register(MailListMailboxesTool())

        // System tools
        register(SystemOpenAppTool())
        register(SystemOpenURLTool())
        register(SystemOpenPathTool())
        register(SystemRevealInFinderTool())
        register(SystemOpenFolderSpecialTool())
        register(SystemOpenSettingsTool())
        register(SystemSearchFilesTool())
        register(SystemSearchAppsTool())
        register(SystemListAppsTool())
        register(SystemRunShortcutTool())
        register(SystemListShortcutsTool())

        logger.info("Registered \(self.tools.count) tools")
    }
    
    /// Register default tools if not already registered (idempotent)
    /// - Returns: true if tools were registered, false if already registered
    @discardableResult
    func registerDefaultToolsIfNeeded() -> Bool {
        guard tools.isEmpty else {
            logger.debug("Default tools already registered, skipping")
            return false
        }
        registerDefaultTools()
        return true
    }
    
    /// Clear all tools (for testing)
    func clear() {
        tools.removeAll()
        logger.debug("Registry cleared")
    }
}
