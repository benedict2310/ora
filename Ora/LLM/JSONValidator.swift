//
//  JSONValidator.swift
//  Ora
//
//  Validates and parses LLM JSON output
//

import Foundation
import os

/// Validates LLM output against expected schema
struct JSONValidator: Sendable {
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "JSONValidator")
    
    /// Parse raw LLM output into structured response
    static func parse(_ output: String) -> Result<LLMOutput, JSONValidationError> {
        // Clean the output (remove markdown, trim)
        let cleaned = cleanOutput(output)
        
        // Parse JSON
        guard let data = cleaned.data(using: .utf8) else {
            return .failure(.invalidEncoding)
        }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.notAnObject)
            }
            
            return parseJSON(json)
        } catch {
            logger.warning("JSON parse error: \(error.localizedDescription)")
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }
    
    private static func cleanOutput(_ output: String) -> String {
        var result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code blocks if present
        if result.hasPrefix("```json") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```") {
            result = String(result.dropFirst(3))
        }
        
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func parseJSON(_ json: [String: Any]) -> Result<LLMOutput, JSONValidationError> {
        guard let type = json["type"] as? String else {
            return .failure(.missingField("type"))
        }
        
        switch type {
        case "response":
            guard let text = json["text"] as? String else {
                return .failure(.missingField("text"))
            }
            return .success(.response(text: text))
            
        case "tool_call":
            guard let tool = json["tool"] as? String else {
                return .failure(.missingField("tool"))
            }
            guard let argsDict = json["args"] as? [String: Any] else {
                return .failure(.missingField("args")) // or .invalidJSON("args must be object")
            }
            return .success(.toolCall(tool: tool, args: convertToJSONValue(argsDict)))
            
        case "proposal":
            guard let summary = json["summary"] as? String,
                  let tool = json["tool"] as? String else {
                return .failure(.missingField("summary or tool"))
            }
            guard let argsDict = json["args"] as? [String: Any] else {
                return .failure(.missingField("args"))
            }
            return .success(.proposal(summary: summary, tool: tool, args: convertToJSONValue(argsDict)))
            
        default:
            return .failure(.unknownType(type))
        }
    }
    
    private static func convertToJSONValue(_ dict: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            result[key] = anyToJSONValue(value)
        }
        return result
    }
    
    private static func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let arr as [Any]:
            return .array(arr.map { anyToJSONValue($0) })
        case let dict as [String: Any]:
            return .object(convertToJSONValue(dict))
        case is NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }
}

/// Validation errors
enum JSONValidationError: LocalizedError, Sendable {
    case invalidEncoding
    case invalidJSON(String)
    case notAnObject
    case missingField(String)
    case unknownType(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Invalid text encoding"
        case .invalidJSON(let detail):
            return "Invalid JSON: \(detail)"
        case .notAnObject:
            return "Expected JSON object at root"
        case .missingField(let field):
            return "Missing required field: \(field)"
        case .unknownType(let type):
            return "Unknown response type: \(type)"
        }
    }
}
