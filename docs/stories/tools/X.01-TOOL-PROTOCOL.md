# X.01 - Tool Protocol

**Epic:** Tools
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** F.02 (Permissions)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Define the base tool protocol, registry, and confirmation gate for all agentic tools.

---

## 2. Implementation

### 2.1 Tool Protocol

**File:** `Ora/Tools/ToolProtocol.swift`

```swift
//
//  ToolProtocol.swift
//  Ora
//
//  Base protocol for all tools
//

import Foundation

/// Tool execution type
enum ToolKind: String, Sendable {
    case read    // No confirmation needed
    case mutate  // Requires confirmation
}

/// Result of tool execution
struct ToolResult: Sendable {
    let json: JSONValue
    let humanSummary: String
    
    static func success(_ json: JSONValue, summary: String) -> ToolResult {
        ToolResult(json: json, humanSummary: summary)
    }
    
    static func error(_ message: String) -> ToolResult {
        ToolResult(json: .object(["error": .string(message)]), humanSummary: message)
    }
}

/// Tool definition for system prompt
struct ToolSchema: Sendable {
    let name: String
    let description: String
    let parameters: [String: ParameterSchema]
    let requiredParameters: [String]
}

struct ParameterSchema: Sendable {
    let type: String  // string, number, boolean, etc.
    let description: String
    let format: String?  // date-time, email, etc.
}

/// Base protocol for all tools
protocol Tool: Sendable {
    /// Unique tool name (e.g., "calendar.create_event")
    var name: String { get }
    
    /// Whether this tool mutates state
    var kind: ToolKind { get }
    
    /// Tool schema for LLM
    var schema: ToolSchema { get }
    
    /// Validate arguments before execution
    func validate(args: [String: JSONValue]) throws
    
    /// Execute the tool
    func execute(args: [String: JSONValue]) async throws -> ToolResult
}

extension Tool {
    /// Whether confirmation is required
    var requiresConfirmation: Bool {
        kind == .mutate
    }
}
```

### 2.2 Tool Registry

**File:** `Ora/Tools/ToolRegistry.swift`

```swift
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
        register(CalendarDeleteEventTool())
        
        // Reminders tools
        register(RemindersListTool())
        register(RemindersCreateTool())
        register(RemindersCompleteTool())
        
        // Contacts tools
        register(ContactsSearchTool())
        
        // System tools
        register(SystemOpenAppTool())
        register(SystemOpenURLTool())
        
        logger.info("Registered \(tools.count) tools")
    }
}
```

### 2.3 Tool Host

**File:** `Ora/Tools/ToolHost.swift`

```swift
//
//  ToolHost.swift
//  Ora
//
//  Executes tools with confirmation and audit logging
//

import Foundation
import os

/// Executes tools with proper guardrails
actor ToolHost {
    
    // MARK: - Singleton
    
    static let shared = ToolHost()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ToolHost")
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Execute a tool call
    func execute(
        toolName: String,
        args: [String: JSONValue],
        confirmed: Bool,
        sessionID: UUID? = nil
    ) async throws -> ToolResult {
        // Get tool
        guard let tool = await ToolRegistry.shared.tool(named: toolName) else {
            throw ToolHostError.toolNotFound(toolName)
        }
        
        // Check confirmation for mutations
        if tool.requiresConfirmation && !confirmed {
            throw ToolHostError.confirmationRequired(toolName)
        }
        
        // Validate arguments
        do {
            try tool.validate(args: args)
        } catch {
            throw ToolHostError.validationFailed(toolName, error.localizedDescription)
        }
        
        // Record audit entry
        let auditEntry = await MainActor.run {
            AuditLogger.shared.recordToolCall(
                tool: toolName,
                action: tool.kind.rawValue,
                parameters: argsToDict(args),
                userConfirmed: confirmed,
                sessionID: sessionID
            )
        }
        
        // Execute
        do {
            let result = try await tool.execute(args: args)
            
            // Update audit
            await MainActor.run {
                AuditLogger.shared.recordSuccess(auditEntry, result: ["summary": result.humanSummary])
            }
            
            logger.info("Tool executed: \(toolName)")
            return result
            
        } catch {
            // Update audit with failure
            await MainActor.run {
                AuditLogger.shared.recordFailure(auditEntry, error: error.localizedDescription)
            }
            
            logger.error("Tool failed: \(toolName) - \(error.localizedDescription)")
            throw error
        }
    }
    
    private func argsToDict(_ args: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in args {
            result[key] = jsonValueToAny(value)
        }
        return result
    }
    
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        }
    }
}

// MARK: - Errors

enum ToolHostError: LocalizedError {
    case toolNotFound(String)
    case confirmationRequired(String)
    case validationFailed(String, String)
    
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool '\(name)' not found."
        case .confirmationRequired(let name):
            return "Tool '\(name)' requires user confirmation."
        case .validationFailed(let name, let reason):
            return "Validation failed for '\(name)': \(reason)"
        }
    }
}
```

---

## 3. Acceptance Criteria

- [ ] **AC-1:** `Tool` protocol defines name, kind, schema, validate, execute
- [ ] **AC-2:** `ToolRegistry` stores and retrieves tools
- [ ] **AC-3:** `ToolHost` enforces confirmation for mutations
- [ ] **AC-4:** All tool calls logged to audit
- [ ] **AC-5:** Validation runs before execution

---

## 4. Implementation Checklist

- [ ] Create `ToolProtocol.swift`
- [ ] Create `ToolRegistry.swift`
- [ ] Create `ToolHost.swift`
- [ ] Add JSONValue extensions if needed
- [ ] Test confirmation enforcement
