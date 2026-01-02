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
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ToolRegistry")
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
        // Will be populated as tools are implemented
        logger.info("Registered \(self.tools.count) tools")
    }
    
    /// Clear all tools (for testing)
    func clear() {
        tools.removeAll()
        logger.debug("Registry cleared")
    }
}
