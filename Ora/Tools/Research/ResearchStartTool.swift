//
//  ResearchStartTool.swift
//  Ora
//
//  Enqueue a background research task for one or more URLs.
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
        }
    }
}

struct ResearchStartTool: Tool {

    // MARK: - Constants

    static let maxURLs = 10
    static let maxURLLength = 2048
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
            description: "Start a background research task that fetches and summarizes one or more URLs. Requires confirmation.",
            parameters: [
                "urls": ParameterSchema(type: "array", description: "List of URLs to research (max \(Self.maxURLs))"),
                "label": ParameterSchema(type: "string", description: "Optional label for the research task")
            ],
            requiredParameters: ["urls"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        let urls = try Self.extractURLs(from: args)
        try Self.validateURLs(urls)
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        let urls = try Self.extractURLs(from: args)
        let label = args["label"]?.stringValue
        let urlList = urls.map { "  - \($0)" }.joined(separator: "\n")
        let summary = label != nil
            ? "Research \(urls.count) URL(s) labeled \"\(label!)\""
            : "Research \(urls.count) URL(s)"

        return ToolAuthorizationPlan(
            requirement: .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Start Research Task",
                    summary: summary,
                    details: urlList,
                    confirmLabel: "Start",
                    cancelLabel: "Cancel"
                )
            ),
            auditMetadata: [
                "url_count": "\(urls.count)",
                "label": label ?? ""
            ]
        )
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let urls = try Self.extractURLs(from: args)
        try Self.validateURLs(urls)
        let label = args["label"]?.stringValue

        // Rate limiting using the real session ID
        let sessionID = await MainActor.run { PersistenceManager.shared.currentSession().id }
        try await Self.rateLimiter.checkAndRecord(sessionID: sessionID)

        guard let manager = await BackgroundTaskManager.resolveShared() else {
            throw ResearchToolError.managerUnavailable
        }

        let inputs = BackgroundTaskInputs(urls: urls, label: label)
        let snapshot = try await manager.enqueue(inputs: inputs, sessionID: sessionID)

        Self.logger.info("Enqueued research task \(snapshot.id) with \(urls.count) URL(s)")

        let resultJSON: JSONValue = .object([
            "task_id": .string(snapshot.id.uuidString),
            "state": .string(snapshot.state.rawValue),
            "label": label.map { .string($0) } ?? .null,
            "message": .string("Research task enqueued successfully.")
        ])

        let summary = label != nil
            ? "Enqueued research task \"\(label!)\" with \(urls.count) URL(s)."
            : "Enqueued research task with \(urls.count) URL(s)."

        return .success(resultJSON, summary: summary)
    }

    // MARK: - Validation Helpers

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
