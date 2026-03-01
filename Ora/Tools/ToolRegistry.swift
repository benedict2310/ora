//
//  ToolRegistry.swift
//  Ora
//
//  Central registry for all available tools
//

import Foundation
import os

struct DeferredToolCatalogRow: Sendable {
    let domain: String
    let name: String
    let requiresConfirmation: Bool
}

/// Central registry of available tools
actor ToolRegistry {
    
    // MARK: - Singleton
    
    static let shared = ToolRegistry()
    
    // MARK: - Properties
    
    private let logger = Logger.ora(category: "ToolRegistry")
    private var tools: [String: any Tool] = [:]
    private var discoveryIndex = ToolDiscoveryIndex(schemas: [])
    private var discoveredToolNamesBySession: [UUID: Set<String>] = [:]
    
    // MARK: - Initialization
    
    private init() {}
    
    /// Create a test instance (not a singleton)
    static func makeTestInstance() -> ToolRegistry {
        return ToolRegistry()
    }
    
    // MARK: - Public API
    
    /// Register a tool
    func register(_ tool: any Tool) {
        self.tools[tool.name] = tool
        self.rebuildDiscoveryIndex()
        self.logger.debug("Registered tool: \(tool.name)")
    }
    
    /// Get a tool by name
    func tool(named name: String) -> (any Tool)? {
        self.tools[name]
    }
    
    /// Get all registered tools
    func allTools() -> [any Tool] {
        self.sortedTools()
    }
    
    /// Get tool schemas for system prompt
    func schemas() -> [ToolSchema] {
        self.sortedTools().map { $0.schema }
    }

    /// Get only core tool schemas (full schema details)
    func coreSchemas() -> [ToolSchema] {
        self.sortedTools()
            .filter { $0.loadPolicy == .core }
            .map { $0.schema }
    }

    /// Get deferred tools as compact catalog rows
    func deferredCatalogRows() -> [DeferredToolCatalogRow] {
        self.sortedTools()
            .filter { $0.loadPolicy == .deferred }
            .map { tool in
                DeferredToolCatalogRow(
                    domain: Self.toolDomain(from: tool.name),
                    name: tool.schema.name,
                    requiresConfirmation: tool.schema.requiresConfirmation
                )
            }
    }

    /// Get discovered schemas for a session
    func discoveredSchemas(for sessionID: UUID) -> [ToolSchema] {
        guard let discoveredNames = self.discoveredToolNamesBySession[sessionID], !discoveredNames.isEmpty else {
            return []
        }

        return discoveredNames
            .compactMap { self.tools[$0]?.schema }
            .sorted(by: { $0.name < $1.name })
    }

    /// Discover deferred tools and cache discovered names per session
    func discoverTools(query: String, limit: Int, sessionID: UUID) -> [ToolDiscoveryMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let clampedLimit = min(max(limit, 1), ToolDiscoveryIndex.maxTopK)
        let matches = self.discoveryIndex.search(query: trimmedQuery, topK: clampedLimit)
        guard !matches.isEmpty else {
            return []
        }

        var discoveredNames = self.discoveredToolNamesBySession[sessionID, default: []]
        for match in matches {
            discoveredNames.insert(match.schema.name)
        }
        self.discoveredToolNamesBySession[sessionID] = discoveredNames

        return matches
    }

    /// Get discovered tool names for a session
    func discoveredToolNames(for sessionID: UUID) -> [String] {
        let names = self.discoveredToolNamesBySession[sessionID] ?? []
        return names.sorted()
    }

    /// Clear discovered cache for a session
    func clearDiscoveredTools(for sessionID: UUID) {
        self.discoveredToolNamesBySession.removeValue(forKey: sessionID)
    }

    /// Migrate discovered tool cache from one session key to another.
    func migrateDiscoveredTools(from sourceSessionID: UUID, to destinationSessionID: UUID) {
        let source = self.discoveredToolNamesBySession[sourceSessionID] ?? []
        guard !source.isEmpty else {
            return
        }

        var destination = self.discoveredToolNamesBySession[destinationSessionID] ?? []
        destination.formUnion(source)
        self.discoveredToolNamesBySession[destinationSessionID] = destination
    }

    /// Clear discovered cache for all sessions
    func clearAllDiscoveredTools() {
        self.discoveredToolNamesBySession.removeAll()
    }

    /// Indexed deferred tool names
    func discoveryIndexedToolNames() -> [String] {
        self.discoveryIndex.indexedToolNames.sorted()
    }
    
    /// Register all default tools
    func registerDefaultTools() {
        // Tool discovery (must be core and always available)
        register(ToolDiscoveryTool())

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
        register(SkillsRunScriptTool())

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

        self.logger.info("Registered \(self.tools.count) tools")
    }
    
    /// Register default tools if not already registered (idempotent)
    /// - Returns: true if tools were registered, false if already registered
    @discardableResult
    func registerDefaultToolsIfNeeded() -> Bool {
        guard self.tools.isEmpty else {
            self.logger.debug("Default tools already registered, skipping")
            return false
        }
        registerDefaultTools()
        return true
    }
    
    /// Clear all tools (for testing)
    func clear() {
        self.tools.removeAll()
        self.discoveryIndex = ToolDiscoveryIndex(schemas: [])
        self.discoveredToolNamesBySession.removeAll()
        self.logger.debug("Registry cleared")
    }

    // MARK: - Private

    private func sortedTools() -> [any Tool] {
        self.tools
            .values
            .sorted { $0.name < $1.name }
    }

    private func rebuildDiscoveryIndex() {
        let deferredSchemas = self.tools
            .values
            .filter { $0.loadPolicy == .deferred }
            .map { $0.schema }

        self.discoveryIndex = ToolDiscoveryIndex(schemas: deferredSchemas)
    }

    private static func toolDomain(from toolName: String) -> String {
        guard let separator = toolName.firstIndex(of: ".") else {
            return toolName
        }
        return String(toolName[..<separator])
    }
}
