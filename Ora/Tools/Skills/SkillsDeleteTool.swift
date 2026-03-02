//
//  SkillsDeleteTool.swift
//  Ora
//
//  Deletes existing agent-authored skills after user confirmation.
//

import Foundation

struct SkillsDeleteTool: Tool {
    let name = "skills.delete"
    let kind: ToolKind = .mutate

    private let skillStore: SkillStore

    init(skillStore: SkillStore = .shared) {
        self.skillStore = skillStore
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "Delete an Ora-created skill. Use only when the user explicitly asks Ora to delete a saved skill.",
            parameters: [
                "id": ParameterSchema(type: "string", description: "Existing skill id")
            ],
            requiredParameters: ["id"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        try SkillAuthoringToolSupport.validateMutationArguments(
            toolName: self.name,
            args: args,
            requireContent: false
        )
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        try await SkillsFeatureGate.requireEnabled()

        let requestedID = args["id"]?.stringValue ?? ""
        let metadata = try await self.skillStore.metadataExact(id: requestedID)
        guard metadata.source == .agent else {
            throw SkillError.immutableSource(requestedID, metadata.source)
        }

        return ToolAuthorizationPlan(
            requirement: .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Delete Skill: \"\(metadata.name)\"",
                    summary: "This skill will be removed from future conversations.",
                    confirmLabel: "Delete Skill",
                    cancelLabel: "Cancel",
                    presentation: .skillDeletion(
                        name: metadata.name,
                        description: metadata.description
                    )
                )
            ),
            auditMetadata: [
                "skillName": metadata.name
            ]
        )
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        try await SkillsFeatureGate.requireEnabled()

        let requestedID = args["id"]?.stringValue ?? ""

        do {
            let metadata = try await self.skillStore.delete(id: requestedID)
            return .success(
                .object([
                    "id": .string(metadata.id),
                    "deleted": .bool(true)
                ]),
                summary: "Deleted skill '\(metadata.name)'.",
                auditPayload: [
                    "skillId": .string(metadata.id),
                    "name": .string(metadata.name)
                ]
            )
        } catch {
            throw SkillAuthoringToolSupport.failure(
                error,
                category: .skillDelete,
                payload: [
                    "skillId": .string(requestedID)
                ]
            )
        }
    }
}
