//
//  SkillsListTool.swift
//  Ora
//
//  Lists available skills metadata.
//

import Foundation

struct SkillsListTool: Tool {
    let name = "skills.list"
    let kind: ToolKind = .read
    private let skillStore: SkillStore

    init(skillStore: SkillStore = .shared) {
        self.skillStore = skillStore
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "List available skills with their name, description, and source. Use when the user asks what skills are available, installed, or saved.",
            parameters: [:],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        // No parameters required.
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        try await SkillsFeatureGate.requireEnabled()

        let skills = await self.skillStore.list()
        let payload: [JSONValue] = skills.map { metadata in
            .object([
                "id": .string(metadata.id),
                "name": .string(metadata.name),
                "description": .string(metadata.description),
                "source": .string(metadata.source.rawValue),
                "has_scripts": .bool(metadata.hasScripts)
            ])
        }

        return .success(
            .array(payload),
            summary: "Found \(skills.count) available skills."
        )
    }
}
