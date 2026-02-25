//
//  ToolDiscoveryTool.swift
//  Ora
//
//  Read-only discovery tool that returns deferred tool schemas by query.
//

import Foundation

struct ToolDiscoveryTool: Tool {
    static let toolName = "tools.discover"
    static let sessionIDArgumentKey = "_session_id"

    let name = Self.toolName
    let kind: ToolKind = .read

    var loadPolicy: ToolLoadPolicy {
        .core
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "Discover deferred tools relevant to a task query. Returns matching tool schemas with confidence scores.",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Natural-language description of the tool you need"),
                "limit": ParameterSchema(type: "number", description: "Maximum matches to return (default 5, max 8)")
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: query")
        }

        if let limit = args["limit"]?.numberValue, limit < 1 {
            throw ToolHostError.validationFailed(self.name, "limit must be at least 1")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestedLimit = Int(args["limit"]?.numberValue ?? Double(ToolDiscoveryIndex.defaultTopK))
        let limit = min(max(requestedLimit, 1), ToolDiscoveryIndex.maxTopK)
        let sessionID = self.resolveSessionID(from: args) ?? UUID()

        let matches = await ToolRegistry.shared.discoverTools(
            query: query,
            limit: limit,
            sessionID: sessionID
        )

        let matchObjects: [JSONValue] = matches.map { match in
            .object([
                "name": .string(match.schema.name),
                "description": .string(match.schema.description),
                "parameters": .object(self.encodeParameters(match.schema.parameters)),
                "requiredParameters": .array(match.schema.requiredParameters.map { .string($0) }),
                "requiresConfirmation": .bool(match.schema.requiresConfirmation),
                "score": .number(match.score)
            ])
        }

        let matchedNames = matches.map { $0.schema.name }
        let summary: String
        if matchedNames.isEmpty {
            summary = "No tools matched '\(query)'."
        } else {
            summary = "Matched tools: \(matchedNames.joined(separator: ", "))."
        }

        let json: JSONValue = .object([
            "query": .string(query),
            "matches": .array(matchObjects),
            "matchedNames": .array(matchedNames.map { .string($0) }),
            "count": .number(Double(matchedNames.count))
        ])

        return .success(json, summary: summary)
    }

    // MARK: - Helpers

    private func resolveSessionID(from args: [String: JSONValue]) -> UUID? {
        guard let raw = args[Self.sessionIDArgumentKey]?.stringValue else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func encodeParameters(_ parameters: [String: ParameterSchema]) -> [String: JSONValue] {
        var encoded: [String: JSONValue] = [:]
        for (name, parameter) in parameters.sorted(by: { $0.key < $1.key }) {
            var value: [String: JSONValue] = [
                "type": .string(parameter.type),
                "description": .string(parameter.description)
            ]
            if let format = parameter.format {
                value["format"] = .string(format)
            }
            encoded[name] = .object(value)
        }
        return encoded
    }
}
