//
//  ResearchLoadResultTool.swift
//  Ora
//
//  Load a compact summary payload from a completed research task.
//

import Foundation
import os

struct ResearchLoadResultTool: Tool {

    // MARK: - Constants

    static let maxSummaryLength = 4000
    static let maxCitations = 20

    // MARK: - Tool Protocol

    let name = "research.load_result"
    let kind: ToolKind = .read

    private static let logger = Logger.ora(category: "tools")

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Load the summary and citations from a completed research task into the conversation.",
            parameters: [
                "task_id": ParameterSchema(type: "string", description: "The UUID of the research task to load")
            ],
            requiredParameters: ["task_id"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let taskIDStr = args["task_id"]?.stringValue, !taskIDStr.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: task_id")
        }
        guard UUID(uuidString: taskIDStr) != nil else {
            throw ToolHostError.validationFailed(name, "Parameter 'task_id' must be a valid UUID.")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let taskIDStr = args["task_id"]?.stringValue,
              let taskID = UUID(uuidString: taskIDStr) else {
            throw ToolHostError.validationFailed(name, "Invalid task_id.")
        }

        // Try to read the artifact
        let artifact: StoredArtifact
        do {
            artifact = try await ArtifactStore.shared.read(taskID: taskID)
        } catch {
            Self.logger.error("Failed to load research result for task \(taskIDStr): \(error.localizedDescription)")
            return .error("Research result not found for task \(taskIDStr).")
        }

        // Build summary: prefer summary.md file if it exists, fall back to result summary
        let summaryText = Self.loadSummary(artifact: artifact)
        let cappedSummary = Self.capString(summaryText, maxLength: Self.maxSummaryLength)

        // Build citations array (capped)
        let cappedCitations = Array(artifact.citations.prefix(Self.maxCitations))
        let citationsJSON: [JSONValue] = cappedCitations.map { citation in
            .object([
                "url": .string(citation.url),
                "title": citation.title.map { .string($0) } ?? .null,
                "snippet": .string(citation.snippet)
            ])
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var resultObj: [String: JSONValue] = [
            "task_id": .string(taskID.uuidString),
            "label": artifact.manifest.label.map { .string($0) } ?? .null,
            "completed_at": .string(formatter.string(from: artifact.manifest.completedAt)),
            "summary": .string(cappedSummary),
            "citations": .array(citationsJSON)
        ]

        // Include query if available
        if let query = artifact.result.query {
            resultObj["query"] = .string(query)
        }

        // Include provenance if available
        if let provenance = artifact.result.provenance {
            if let searchQueries = provenance.searchQueries, !searchQueries.isEmpty {
                resultObj["search_queries_used"] = .array(searchQueries.map { .string($0) })
            }
            if let rationale = provenance.discoveryRationale {
                resultObj["discovery_rationale"] = .string(rationale)
            }
            if let domains = provenance.domainsUsed, !domains.isEmpty {
                resultObj["domains_used"] = .array(domains.map { .string($0) })
            }
        }

        let resultJSON: JSONValue = .object(resultObj)

        let label = artifact.manifest.label ?? taskID.uuidString.prefix(8).description
        let summary = "Loaded research result: \(label) (\(cappedCitations.count) citations)."

        Self.logger.info("Loaded research result \(taskIDStr) with \(cappedCitations.count) citations")

        return .success(resultJSON, summary: summary)
    }

    // MARK: - Helpers

    /// Try to load summary.md from the artifact path first, falling back to the extractive summary.
    static func loadSummary(artifact: StoredArtifact) -> String {
        let artifactURL = URL(fileURLWithPath: artifact.manifest.artifactPath)
        let summaryURL = artifactURL.appendingPathComponent("summary.md")

        if let summaryData = try? Data(contentsOf: summaryURL),
           let summaryContent = String(data: summaryData, encoding: .utf8),
           !summaryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summaryContent
        }

        // Fall back to the extractive summary from result.json
        return artifact.result.summary
    }

    static func capString(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else {
            return string
        }
        return String(string.prefix(maxLength - 3)) + "..."
    }
}
