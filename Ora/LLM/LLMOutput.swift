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

    /// Short label for logging (e.g. "response", "tool_call:mail.recent")
    var typeLabel: String {
        switch self {
        case .response: return "response"
        case .toolCall(let tool, _): return "tool_call:\(tool)"
        case .proposal(_, let tool, _): return "proposal:\(tool)"
        case .error: return "error"
        }
    }
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

    /// Convert to compact JSON string (single line, no extra whitespace)
    var compactJSON: String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(self)
            return String(data: data, encoding: .utf8) ?? stringDescription
        } catch {
            return stringDescription
        }
    }

    /// Simple string description for debugging
    var stringDescription: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let arr): return "[\(arr.map { $0.stringDescription }.joined(separator: ","))]"
        case .object(let obj): return "{\(obj.map { "\"\($0.key)\":\($0.value.stringDescription)" }.joined(separator: ","))}"
        }
    }
}
