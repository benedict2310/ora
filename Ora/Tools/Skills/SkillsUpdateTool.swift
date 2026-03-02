//
//  SkillsUpdateTool.swift
//  Ora
//
//  Updates existing agent-authored skills after user confirmation.
//

import Foundation

struct SkillsUpdateTool: Tool {
    let name = "skills.update"
    let kind: ToolKind = .mutate

    private let skillStore: SkillStore

    init(skillStore: SkillStore = .shared) {
        self.skillStore = skillStore
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "Rewrite an existing Ora-created skill. Use only when the user explicitly asks Ora to update a saved skill.",
            parameters: [
                "id": ParameterSchema(type: "string", description: "Existing skill id"),
                "content": ParameterSchema(type: "string", description: "Replacement SKILL.md markdown")
            ],
            requiredParameters: ["id", "content"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        try SkillAuthoringToolSupport.validateMutationArguments(
            toolName: self.name,
            args: args,
            requireContent: true
        )
    }

    func auditParameters(args: [String: JSONValue]) -> [String: JSONValue] {
        SkillAuthoringToolSupport.redactUpdateAuditParameters(args: args)
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        try await SkillsFeatureGate.requireEnabled()

        let requestedID = args["id"]?.stringValue ?? ""
        let metadata = try await self.skillStore.metadataExact(id: requestedID)
        guard metadata.source == .agent else {
            throw SkillError.immutableSource(requestedID, metadata.source)
        }

        let sanitized = try SkillAuthoringToolSupport.sanitizedSkillContent(args["content"]?.stringValue ?? "")

        return ToolAuthorizationPlan(
            requirement: .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Update Skill: \"\(metadata.name)\"",
                    summary: "This skill will be updated and the new instructions will be used in future conversations.",
                    confirmLabel: "Save Changes",
                    cancelLabel: "Cancel",
                    presentation: .skillDocumentPreview(content: sanitized)
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
            let sanitized = try SkillAuthoringToolSupport.sanitizedSkillContent(args["content"]?.stringValue ?? "")
            let metadata = try await self.skillStore.update(id: requestedID, content: sanitized)
            let contentHash = SkillAuthoringToolSupport.contentHash(for: sanitized)

            return .success(
                .object([
                    "id": .string(metadata.id),
                    "name": .string(metadata.name)
                ]),
                summary: "Updated skill '\(metadata.name)'.",
                auditPayload: [
                    "skillId": .string(metadata.id),
                    "name": .string(metadata.name),
                    "contentHash": .string(contentHash)
                ]
            )
        } catch {
            throw SkillAuthoringToolSupport.failure(
                error,
                category: .skillUpdate,
                payload: [
                    "skillId": .string(requestedID)
                ]
            )
        }
    }
}
