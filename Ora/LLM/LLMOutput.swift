//
//  LLMOutput.swift
//  Ora
//
//  Structured output types from LLM
//

import Foundation

/// Parsed LLM response
enum LLMOutput: Sendable, Equatable {
    /// Direct text response (no tool call)
    case response(text: String)
    
    /// Tool call request
    case toolCall(tool: String, args: [String: JSONValue])
    
    /// Proposal for mutation (requires confirmation)
    case proposal(summary: String, tool: String, args: [String: JSONValue])
    
    /// Error in parsing
    case error(message: String)
}

/// JSON value for tool arguments
enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
    
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    
    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
