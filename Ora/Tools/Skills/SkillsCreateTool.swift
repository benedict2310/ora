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
                "content": ParameterSchema(type: "string", description: "Full SKILL.md markdown. MUST begin with a YAML frontmatter block containing name and description, e.g.: ---\\nname: Skill Name\\ndescription: What this skill does.\\n---\\n\\n# Skill Name\\n## Procedure\\n1. Step one")
            ],
            requiredParameters: ["content"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let content = args["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: content")
        }
        _ = try SkillAuthoringToolSupport.sanitizedSkillContent(content)
    }

    func auditParameters(args: [String: JSONValue]) -> [String: JSONValue] {
        ["contentLength": .number(Double(args["content"]?.stringValue?.count ?? 0))]
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        try await SkillsFeatureGate.requireEnabled()
        let sanitized = try SkillAuthoringToolSupport.sanitizedSkillContent(args["content"]?.stringValue ?? "")
        let frontmatter = try SkillFrontmatterParser.parse(from: sanitized)

        return ToolAuthorizationPlan(
            requirement: .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Save Skill: \"\(frontmatter.name)\"",
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

        do {
            let sanitized = try SkillAuthoringToolSupport.sanitizedSkillContent(args["content"]?.stringValue ?? "")
            let frontmatter = try SkillFrontmatterParser.parse(from: sanitized)
            let metadata = try await self.skillStore.create(name: frontmatter.name, content: sanitized)
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
                payload: nil
            )
        }
    }
}
