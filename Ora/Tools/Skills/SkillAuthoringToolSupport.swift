//
//  SkillAuthoringToolSupport.swift
//  Ora
//
//  Shared helpers for skill authoring tools.
//

import CryptoKit
import Foundation

struct SkillAuthoringToolFailure: ToolAuditableFailure {
    let message: String
    let auditPayload: [String: JSONValue]?
    let auditCategoryOverride: AuditCategory?

    var errorDescription: String? {
        self.message
    }
}

enum SkillAuthoringToolSupport {

    // MARK: - Validation

    static func validateCreateArguments(
        toolName: String,
        args: [String: JSONValue]
    ) throws {
        guard let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw ToolHostError.validationFailed(toolName, "Missing required parameter: name")
        }

        guard let description = args["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            throw ToolHostError.validationFailed(toolName, "Missing required parameter: description")
        }

        guard let content = args["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ToolHostError.validationFailed(toolName, "Missing required parameter: content")
        }

        _ = try Self.sanitizedSkillContent(content)
    }

    static func validateMutationArguments(
        toolName: String,
        args: [String: JSONValue],
        requireContent: Bool
    ) throws {
        guard let id = args["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            throw ToolHostError.validationFailed(toolName, "Missing required parameter: id")
        }

        if requireContent {
            guard let content = args["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw ToolHostError.validationFailed(toolName, "Missing required parameter: content")
            }

            _ = try Self.sanitizedSkillContent(content)
        }
    }

    // MARK: - Content

    static func sanitizedSkillContent(_ content: String) throws -> String {
        let sanitized = ContentSanitizer.sanitize(content)
        _ = try SkillFrontmatterParser.parse(from: sanitized)
        return sanitized
    }

    static func contentHash(for content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Audit

    static func redactCreateAuditParameters(args: [String: JSONValue]) -> [String: JSONValue] {
        [
            "name": args["name"] ?? .string(""),
            "description": args["description"] ?? .string(""),
            "contentLength": .number(Double(args["content"]?.stringValue?.count ?? 0))
        ]
    }

    static func redactUpdateAuditParameters(args: [String: JSONValue]) -> [String: JSONValue] {
        [
            "id": args["id"] ?? .string(""),
            "contentLength": .number(Double(args["content"]?.stringValue?.count ?? 0))
        ]
    }

    static func failure(
        _ error: Error,
        category: AuditCategory,
        payload: [String: JSONValue]? = nil
    ) -> SkillAuthoringToolFailure {
        SkillAuthoringToolFailure(
            message: error.localizedDescription,
            auditPayload: payload,
            auditCategoryOverride: category
        )
    }
}
