//
//  SkillsReadTool.swift
//  Ora
//
//  Reads skill reference and asset files through sandboxed paths.
//

import Foundation

struct SkillsReadTool: Tool {
    let name = "skills.read"
    let kind: ToolKind = .read
    private let skillStore: SkillStore

    init(skillStore: SkillStore = .shared) {
        self.skillStore = skillStore
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "Read skill files from references/ or assets/.",
            parameters: [
                "id": ParameterSchema(type: "string", description: "Skill id or spoken skill name"),
                "path": ParameterSchema(type: "string", description: "Relative file path (references/... or assets/...)")
            ],
            requiredParameters: ["id", "path"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let id = args["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: id")
        }

        guard let path = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: path")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        try await SkillsFeatureGate.requireEnabled()

        guard let requestedID = args["id"]?.stringValue,
              let path = args["path"]?.stringValue else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameters")
        }

        let data = try await self.skillStore.readFile(id: requestedID, relativePath: path)

        if let text = String(data: data, encoding: .utf8) {
            let payload: JSONValue = .object([
                "id": .string(requestedID),
                "path": .string(path),
                "encoding": .string("utf8"),
                "content": .string(text)
            ])
            return .success(payload, summary: "Read \(path) from skill '\(requestedID)'.")
        }

        let payload: JSONValue = .object([
            "id": .string(requestedID),
            "path": .string(path),
            "encoding": .string("base64"),
            "content": .string(data.base64EncodedString())
        ])
        return .success(payload, summary: "Read binary file \(path) from skill '\(requestedID)'.")
    }
}
