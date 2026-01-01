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
    
    init(type: String, description: String, format: String? = nil) {
        self.type = type
        self.description = description
        self.format = format
    }
    
    var descriptionString: String {
        var desc = "\(type): \(description)"
        if let format = format {
            desc += " (\(format))"
        }
        return desc
    }
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
