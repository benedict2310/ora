//
//  SkillsCreateTool.swift
//  Ora
//
//  Creates new agent-authored skills after user confirmation.
//

import Foundation

struct SkillsCreateTool: Tool {
    let name = "skills.create"
    let kind: ToolKind = .mutate

    private let skillStore: SkillStore

    init(skillStore: SkillStore = .shared) {
        self.skillStore = skillStore
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "Create and save a new skill for future conversations. Use only when the user explicitly asks Ora to create or save a skill.",
            parameters: [
                "name": ParameterSchema(type: "string", description: "Skill name"),
                "description": ParameterSchema(type: "string", description: "Short skill description"),
                "content": ParameterSchema(type: "string", description: "Full SKILL.md markdown to write")
            ],
            requiredParameters: ["name", "description", "content"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        try SkillAuthoringToolSupport.validateCreateArguments(toolName: self.name, args: args)
    }

    func auditParameters(args: [String: JSONValue]) -> [String: JSONValue] {
        SkillAuthoringToolSupport.redactCreateAuditParameters(args: args)
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        try await SkillsFeatureGate.requireEnabled()
        let proposedName = args["name"]?.stringValue ?? ""
        let sanitized = try SkillAuthoringToolSupport.sanitizedSkillContent(args["content"]?.stringValue ?? "")

        return ToolAuthorizationPlan(
            requirement: .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Save Skill: \"\(proposedName)\"",
                    summary: "This skill will be saved and available in all future conversations.",
                    confirmLabel: "Save Skill",
                    cancelLabel: "Cancel",
                    presentation: .skillDocumentPreview(content: sanitized)
                )
            )
        )
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        try await SkillsFeatureGate.requireEnabled()

        let requestedName = args["name"]?.stringValue ?? ""

        do {
            let sanitized = try SkillAuthoringToolSupport.sanitizedSkillContent(args["content"]?.stringValue ?? "")
            let metadata = try await self.skillStore.create(name: requestedName, content: sanitized)
            let contentHash = SkillAuthoringToolSupport.contentHash(for: sanitized)

            return .success(
                .object([
                    "id": .string(metadata.id),
                    "name": .string(metadata.name),
                    "source": .string(metadata.source.rawValue)
                ]),
                summary: "Saved skill '\(metadata.name)'.",
                auditPayload: [
                    "skillId": .string(metadata.id),
                    "name": .string(metadata.name),
                    "source": .string(metadata.source.rawValue),
                    "contentHash": .string(contentHash)
                ]
            )
        } catch {
            throw SkillAuthoringToolSupport.failure(
                error,
                category: .skillCreate,
                payload: [
                    "name": .string(requestedName)
                ]
            )
        }
    }
}
