//
//  SkillsLoadTool.swift
//  Ora
//
//  Loads a skill document by ID or fuzzy-matched name.
//

import Foundation

struct SkillsLoadTool: Tool {
    let name = "skills.load"
    let kind: ToolKind = .read
    private let skillStore: SkillStore

    private static let maxContentCharacters = 5_000

    init(skillStore: SkillStore = .shared) {
        self.skillStore = skillStore
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "Load skill instructions by id or name.",
            parameters: [
                "id": ParameterSchema(
                    type: "string",
                    description: "Skill id or spoken skill name to load"
                )
            ],
            requiredParameters: ["id"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let id = args["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: id")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        try await SkillsFeatureGate.requireEnabled()

        guard let requestedID = args["id"]?.stringValue else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: id")
        }

        let document = try await self.skillStore.load(id: requestedID)
        let (content, wasTruncated) = Self.truncate(document.markdown)

        var payload: [String: JSONValue] = [
            "id": .string(document.meta.id),
            "name": .string(document.meta.name),
            "description": .string(document.meta.description),
            "source": .string(document.meta.source.rawValue),
            "content": .string(content)
        ]

        if wasTruncated {
            payload["truncated"] = .bool(true)
        }

        let summary: String
        if wasTruncated {
            summary = "Loaded skill '\(document.meta.name)' (truncated to \(Self.maxContentCharacters) chars)."
        } else {
            summary = "Loaded skill '\(document.meta.name)'."
        }

        return .success(.object(payload), summary: summary)
    }

    private static func truncate(_ value: String) -> (String, Bool) {
        guard value.count > maxContentCharacters else {
            return (value, false)
        }

        let prefix = String(value.prefix(maxContentCharacters))
        return (prefix + "\n[truncated]", true)
    }
}
