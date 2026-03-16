//
//  ResearchListResultsTool.swift
//  Ora
//
//  List saved background task / artifact metadata (newest first).
//

import Foundation
import os

struct ResearchListResultsTool: Tool {

    // MARK: - Tool Protocol

    let name = "research.list_results"
    let kind: ToolKind = .read

    private static let logger = Logger.ora(category: "tools")

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List completed background research tasks with metadata. Returns newest first.",
            parameters: [
                "limit": ParameterSchema(type: "number", description: "Maximum number of results to return (default 20, max 50)")
            ],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        if let limitValue = args["limit"] {
            guard limitValue.numberValue != nil else {
                throw ToolHostError.validationFailed(name, "Parameter 'limit' must be a number.")
            }
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let requestedLimit = args["limit"]?.numberValue.map { Int($0) } ?? 20
        let limit = max(1, min(requestedLimit, 50))

        let manifests = await ArtifactStore.shared.list(limit: limit)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let items: [JSONValue] = manifests.map { manifest in
            .object([
                "task_id": .string(manifest.taskID.uuidString),
                "label": manifest.label.map { .string($0) } ?? .null,
                "created_at": .string(formatter.string(from: manifest.createdAt)),
                "completed_at": .string(formatter.string(from: manifest.completedAt)),
                "artifact_path": .string(manifest.artifactPath),
                "citation_count": .number(Double(manifest.citationCount)),
                "page_count": .number(Double(manifest.pageCount))
            ])
        }

        let summary: String
        if manifests.isEmpty {
            summary = "No research results found."
        } else if manifests.count == 1 {
            let label = manifests[0].label ?? manifests[0].taskID.uuidString.prefix(8).description
            summary = "Found 1 research result: \(label)."
        } else {
            summary = "Found \(manifests.count) research results."
        }

        Self.logger.info("Listed \(manifests.count) research results")

        return .success(.array(items), summary: summary)
    }
}
