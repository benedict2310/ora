//
//  ResearchStartTool.swift
//  Ora
//
//  Enqueue a background research task for topic-based or URL-based research.
//

import Foundation
import os

enum ResearchToolError: LocalizedError, Equatable {
    case tooManyURLs(count: Int, limit: Int)
    case urlTooLong(url: String, limit: Int)
    case forbiddenScheme(scheme: String)
    case invalidURL(url: String)
    case sessionLimitExceeded(limit: Int)
    case cooldownActive(remainingSeconds: Int)
    case managerUnavailable
    case queryTooLong(length: Int, limit: Int)
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .tooManyURLs(let count, let limit):
            return "Too many URLs (\(count)). Maximum is \(limit)."
        case .urlTooLong(let url, let limit):
            let truncated = String(url.prefix(60))
            return "URL too long (\(truncated)...). Maximum length is \(limit) characters."
        case .forbiddenScheme(let scheme):
            return "URL scheme '\(scheme)' is not allowed."
        case .invalidURL(let url):
            let truncated = String(url.prefix(60))
            return "Invalid URL: \(truncated)"
        case .sessionLimitExceeded(let limit):
            return "Session limit reached. Maximum \(limit) research tasks per session."
        case .cooldownActive(let remainingSeconds):
            return "Please wait \(remainingSeconds) seconds before enqueuing another research task."
        case .managerUnavailable:
            return "Background task system is not available."
        case .queryTooLong(let length, let limit):
            return "Query too long (\(length) chars). Maximum is \(limit) characters."
        case .emptyInput:
            return "Either a research query or at least one URL is required."
        }
    }
}

struct ResearchStartTool: Tool {

    // MARK: - Constants

    static let maxURLs = 10
    static let maxURLLength = 2048
    static let maxQueryLength = 500
    static let sessionTaskLimit = 5
    static let cooldownSeconds: TimeInterval = 30
    static let forbiddenSchemes: Set<String> = ["data", "javascript", "file"]

    // MARK: - Tool Protocol

    let name = "research.start"
    let kind: ToolKind = .mutate

    private static let logger = Logger.ora(category: "tools")

    /// Per-session enqueue tracking for rate limiting.
    /// Key = sessionID, value = (count, lastEnqueueTime).
    private static let rateLimiter = ResearchRateLimiter()

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Start a background research task. Provide a topic query for autonomous research, or specific URLs to fetch and summarize.",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Research topic in natural language"),
                "urls": ParameterSchema(type: "array", description: "List of URLs to research (max \(Self.maxURLs)). Optional if query is provided."),
                "label": ParameterSchema(type: "string", description: "Optional label for the research task")
            ],
            requiredParameters: [],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        let query = Self.extractQuery(from: args)
        let urls = try Self.extractURLsOptional(from: args)

        // At least one of query or urls must be present
        guard query != nil || !(urls?.isEmpty ?? true) else {
            throw ResearchToolError.emptyInput
        }

        if let query = query {
            try Self.validateQuery(query)
        }

        if let urls = urls, !urls.isEmpty {
            try Self.validateURLs(urls)
        }
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        let query = Self.extractQuery(from: args)
        let urls = try Self.extractURLsOptional(from: args)
        let label = args["label"]?.stringValue

        let summary: String
        let details: String?

        if let query = query, let urls = urls, !urls.isEmpty {
            // Mixed: query + explicit URLs
            let urlList = urls.map { "  - \($0)" }.joined(separator: "\n")
            summary = label ?? "Research: \(query)"
            details = "This will search the public web, fetch sources in the background, and include these specific URLs:\n\(urlList)"
        } else if let query = query {
            // Query-only
            summary = label ?? "Research: \(query)"
            details = "This will search the public web and fetch sources in the background."
        } else if let urls = urls, !urls.isEmpty {
            // URL-only (backward-compatible)
            let urlList = urls.map { "  - \($0)" }.joined(separator: "\n")
            summary = label ?? "Research \(urls.count) URL(s)"
            details = urlList
        } else {
            summary = "Start Research Task"
            details = nil
        }

        return ToolAuthorizationPlan(
            requirement: .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Start Research Task",
                    summary: summary,
                    details: details,
                    confirmLabel: "Start",
                    cancelLabel: "Cancel"
                )
            ),
            auditMetadata: [
                "query": query ?? "",
                "url_count": "\(urls?.count ?? 0)",
                "label": label ?? ""
            ]
        )
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let query = Self.extractQuery(from: args)
        let urls = try Self.extractURLsOptional(from: args)
        let label = args["label"]?.stringValue

        // Validate at least one input
        guard query != nil || !(urls?.isEmpty ?? true) else {
            throw ResearchToolError.emptyInput
        }

        if let query = query {
            try Self.validateQuery(query)
        }
        if let urls = urls, !urls.isEmpty {
            try Self.validateURLs(urls)
        }

        // Rate limiting using the real session ID
        let sessionID = await MainActor.run { PersistenceManager.shared.currentSession().id }
        try await Self.rateLimiter.checkAndRecord(sessionID: sessionID)

        guard let manager = await BackgroundTaskManager.resolveShared() else {
            throw ResearchToolError.managerUnavailable
        }

        let inputs = BackgroundTaskInputs(urls: urls ?? [], label: label, query: query)
        let snapshot = try await manager.enqueue(inputs: inputs, sessionID: sessionID)

        if let query = query {
            Self.logger.info("Enqueued research task \(snapshot.id) with query: \(query)")
        } else {
            Self.logger.info("Enqueued research task \(snapshot.id) with \(urls?.count ?? 0) URL(s)")
        }

        let resultJSON: JSONValue = .object([
            "task_id": .string(snapshot.id.uuidString),
            "state": .string(snapshot.state.rawValue),
            "label": label.map { .string($0) } ?? .null,
            "message": .string("Research task enqueued successfully.")
        ])

        let summary: String
        if let query = query {
            summary = "Enqueued research task for: \(query)."
        } else {
            let urlCount = urls?.count ?? 0
            summary = label != nil
                ? "Enqueued research task \"\(label!)\" with \(urlCount) URL(s)."
                : "Enqueued research task with \(urlCount) URL(s)."
        }

        return .success(resultJSON, summary: summary)
    }

    // MARK: - Validation Helpers

    static func extractQuery(from args: [String: JSONValue]) -> String? {
        guard let queryValue = args["query"]?.stringValue else {
            return nil
        }
        let trimmed = queryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func validateQuery(_ query: String) throws {
        guard query.count <= maxQueryLength else {
            throw ResearchToolError.queryTooLong(length: query.count, limit: maxQueryLength)
        }
    }

    static func extractURLsOptional(from args: [String: JSONValue]) throws -> [String]? {
        guard let urlsValue = args["urls"] else {
            return nil
        }

        let urlStrings: [String]
        switch urlsValue {
        case .array(let values):
            urlStrings = values.compactMap { $0.stringValue }
        case .string(let single):
            urlStrings = [single]
        default:
            throw ToolHostError.validationFailed("research.start", "Parameter 'urls' must be an array of strings.")
        }

        return urlStrings.isEmpty ? nil : urlStrings
    }

    static func extractURLs(from args: [String: JSONValue]) throws -> [String] {
        guard let urlsValue = args["urls"] else {
            throw ToolHostError.validationFailed("research.start", "Missing required parameter: urls")
        }

        let urlStrings: [String]
        switch urlsValue {
        case .array(let values):
            urlStrings = values.compactMap { $0.stringValue }
        case .string(let single):
            urlStrings = [single]
        default:
            throw ToolHostError.validationFailed("research.start", "Parameter 'urls' must be an array of strings.")
        }

        guard !urlStrings.isEmpty else {
            throw ToolHostError.validationFailed("research.start", "At least one URL is required.")
        }

        return urlStrings
    }

    static func validateURLs(_ urls: [String]) throws {
        guard urls.count <= maxURLs else {
            throw ResearchToolError.tooManyURLs(count: urls.count, limit: maxURLs)
        }

        for url in urls {
            guard url.count <= maxURLLength else {
                throw ResearchToolError.urlTooLong(url: url, limit: maxURLLength)
            }

            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
                throw ResearchToolError.invalidURL(url: url)
            }

            if forbiddenSchemes.contains(scheme) {
                throw ResearchToolError.forbiddenScheme(scheme: scheme)
            }
        }
    }
}

// MARK: - Rate Limiter

actor ResearchRateLimiter {
    private var sessionCounts: [UUID: Int] = [:]
    private var sessionLastEnqueueTime: [UUID: Date] = [:]

    func checkAndRecord(sessionID: UUID) throws {
        let now = Date()

        // Per-session cooldown check
        if let lastTime = self.sessionLastEnqueueTime[sessionID] {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed < ResearchStartTool.cooldownSeconds {
                let remaining = Int(ceil(ResearchStartTool.cooldownSeconds - elapsed))
                throw ResearchToolError.cooldownActive(remainingSeconds: remaining)
            }
        }

        // Session limit check
        let count = self.sessionCounts[sessionID, default: 0]
        if count >= ResearchStartTool.sessionTaskLimit {
            throw ResearchToolError.sessionLimitExceeded(limit: ResearchStartTool.sessionTaskLimit)
        }

        // Record
        self.sessionCounts[sessionID] = count + 1
        self.sessionLastEnqueueTime[sessionID] = now
    }

    func reset() {
        self.sessionCounts.removeAll()
        self.sessionLastEnqueueTime.removeAll()
    }
}
