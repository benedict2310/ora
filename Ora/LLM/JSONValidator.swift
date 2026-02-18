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
    
    private static let logger = Logger.ora(category: "JSONValidator")
    
    /// Parse raw LLM output into structured response
    static func parse(_ output: String) -> Result<LLMOutput, JSONValidationError> {
        // Clean the output (remove markdown, trim)
        let cleaned = cleanOutput(output)

        // Fast path: direct parse
        if case .success(let parsed) = parseObjectString(cleaned) {
            return .success(parsed)
        }

        // Fallback: extract JSON object candidates from mixed output and try each.
        for candidate in jsonObjectCandidates(from: cleaned) {
            if case .success(let parsed) = parseObjectString(candidate) {
                return .success(parsed)
            }
        }

        // Return best-effort failure signal for diagnostics.
        switch parseObjectString(cleaned) {
        case .success:
            return .failure(.invalidJSON("Unexpected success state"))
        case .failure(let error):
            return .failure(error)
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
        if let nested = firstNestedTypedObject(in: json) {
            return parseJSON(nested)
        }

        guard let type = json["type"] as? String else {
            return .failure(.missingField("type"))
        }
        
        switch type {
        case "response":
            if let text = responseText(from: json) {
                return .success(.response(text: text))
            }
            guard let text = json["text"] as? String, !text.isEmpty else {
                return .failure(.missingField("text"))
            }
            return .success(.response(text: text))
            
        case "tool_call":
            guard let tool = toolName(from: json) else {
                return .failure(.missingField("tool"))
            }
            guard let argsDict = toolArgs(from: json) else {
                return .failure(.missingField("args"))
            }
            return .success(.toolCall(tool: tool, args: convertToJSONValue(argsDict)))
            
        case "proposal":
            guard let summary = proposalSummary(from: json),
                  let tool = toolName(from: json) else {
                return .failure(.missingField("summary or tool"))
            }
            guard let argsDict = toolArgs(from: json) else {
                return .failure(.missingField("args"))
            }
            return .success(.proposal(summary: summary, tool: tool, args: convertToJSONValue(argsDict)))
            
        case "error":
            guard let message = json["message"] as? String else {
                return .failure(.missingField("message"))
            }
            return .success(.error(message: message))
            
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

    private static func parseObjectString(_ value: String) -> Result<LLMOutput, JSONValidationError> {
        guard let data = value.data(using: .utf8) else {
            return .failure(.invalidEncoding)
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            if let json = object as? [String: Any] {
                return parseJSON(json)
            }
            return .failure(.notAnObject)
        } catch {
            logger.warning("JSON parse error: \(error.localizedDescription)")
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    private static func responseText(from json: [String: Any]) -> String? {
        let candidateKeys = ["text", "response", "message", "content", "output_text", "answer"]
        for key in candidateKeys {
            if let value = json[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func toolName(from json: [String: Any]) -> String? {
        let candidateKeys = ["tool", "name"]
        for key in candidateKeys {
            if let value = json[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func proposalSummary(from json: [String: Any]) -> String? {
        let candidateKeys = ["summary", "description", "text"]
        for key in candidateKeys {
            if let value = json[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func toolArgs(from json: [String: Any]) -> [String: Any]? {
        if let args = json["args"] as? [String: Any] {
            return args
        }
        if let args = json["arguments"] as? [String: Any] {
            return args
        }
        if let argumentsString = json["arguments"] as? String,
           let data = argumentsString.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    private static func firstNestedTypedObject(in json: [String: Any]) -> [String: Any]? {
        for value in json.values {
            if let nested = value as? [String: Any],
               nested["type"] != nil {
                return nested
            }
        }
        return nil
    }

    private static func jsonObjectCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var isInString = false
        var isEscaping = false
        var startIndex: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if isEscaping {
                isEscaping = false
                index = text.index(after: index)
                continue
            }

            if character == "\\" {
                if isInString {
                    isEscaping = true
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                isInString.toggle()
                index = text.index(after: index)
                continue
            }

            if isInString {
                index = text.index(after: index)
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let start = startIndex {
                        let candidate = String(text[start...index])
                        candidates.append(candidate)
                        if candidates.count >= 8 {
                            break
                        }
                        depth = 0
                        isInString = false
                        isEscaping = false
                        startIndex = nil
                    }
                }
            }

            index = text.index(after: index)
        }

        return candidates
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
