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
                "content": ParameterSchema(type: "string", description: "Full SKILL.md markdown. MUST begin with a YAML frontmatter block containing name and description, e.g.: ---\\nname: Skill Name\\ndescription: What this skill does.\\n---\\n\\n# Skill Name\\n## Procedure\\n1. Step one"),
                "scripts": ParameterSchema(type: "object", description: "Optional executable scripts to bundle with the skill. Keys are filenames (e.g. 'hello.py'), values are the full script source. Supported extensions: .py .sh .zsh .rb .js .applescript")
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

        if let scripts = args["scripts"]?.objectValue {
            for (filename, value) in scripts {
                try Self.validateScriptFilename(filename, toolName: self.name)
                guard let source = value.stringValue, !source.isEmpty else {
                    throw ToolHostError.validationFailed(self.name, "Script '\(filename)' must have a non-empty string value")
                }
            }
        }
    }

    func auditParameters(args: [String: JSONValue]) -> [String: JSONValue] {
        let scriptNames = (args["scripts"]?.objectValue ?? [:]).keys.sorted()
        return [
            "contentLength": .number(Double(args["content"]?.stringValue?.count ?? 0)),
            "scripts": .array(scriptNames.map { .string($0) })
        ]
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        try await SkillsFeatureGate.requireEnabled()
        let sanitized = try SkillAuthoringToolSupport.sanitizedSkillContent(args["content"]?.stringValue ?? "")
        let frontmatter = try SkillFrontmatterParser.parse(from: sanitized)
        let scriptNames = (args["scripts"]?.objectValue ?? [:]).keys.sorted()

        let summary: String
        if scriptNames.isEmpty {
            summary = "This skill will be saved and available in all future conversations."
        } else {
            summary = "This skill (including scripts: \(scriptNames.joined(separator: ", "))) will be saved and available in all future conversations."
        }

        return ToolAuthorizationPlan(
            requirement: .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Save Skill: \"\(frontmatter.name)\"",
                    summary: summary,
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
            let scripts = (args["scripts"]?.objectValue ?? [:]).mapValues { $0.stringValue ?? "" }
            let metadata = try await self.skillStore.create(name: frontmatter.name, content: sanitized, scripts: scripts)
            let contentHash = SkillAuthoringToolSupport.contentHash(for: sanitized)

            return .success(
                .object([
                    "id": .string(metadata.id),
                    "name": .string(metadata.name),
                    "source": .string(metadata.source.rawValue),
                    "scripts": .array(scripts.keys.sorted().map { .string($0) })
                ]),
                summary: scripts.isEmpty
                    ? "Saved skill '\(metadata.name)'."
                    : "Saved skill '\(metadata.name)' with \(scripts.count) script(s).",
                auditPayload: [
                    "skillId": .string(metadata.id),
                    "name": .string(metadata.name),
                    "source": .string(metadata.source.rawValue),
                    "contentHash": .string(contentHash),
                    "scriptCount": .number(Double(scripts.count))
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

    private static func validateScriptFilename(_ filename: String, toolName: String) throws {
        guard !filename.isEmpty else {
            throw ToolHostError.validationFailed(toolName, "Script filename must not be empty")
        }
        guard !filename.contains("/") else {
            throw ToolHostError.validationFailed(toolName, "Script filename must not contain path separators: \(filename)")
        }
        guard filename != "manifest.json" else {
            throw ToolHostError.validationFailed(toolName, "Script filename 'manifest.json' is reserved")
        }
        let supported = ["py", "sh", "zsh", "rb", "js", "mjs", "applescript", "scpt"]
        let ext = (filename as NSString).pathExtension.lowercased()
        guard supported.contains(ext) else {
            throw ToolHostError.validationFailed(toolName, "Unsupported script extension '.\(ext)'. Supported: \(supported.joined(separator: ", "))")
        }
    }
}
