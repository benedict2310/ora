//
//  SystemSearchAppsTool.swift
//  Ora
//
//  Search installed applications
//

import Foundation

struct SystemSearchAppsTool: Tool {
    let name = "system.search_apps"
    let kind: ToolKind = .read

    struct AppMatch {
        let name: String
        let bundleId: String?
        let path: String
        let matchScore: Double?
    }
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search installed applications by name",
            parameters: [
                "query": ParameterSchema(type: "string", description: "App name to search for"),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 5)")
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let query = args["query"]?.stringValue else {
            throw SystemToolError.invalidArgument("Query required")
        }
        
        let limit = Int(args["limit"]?.numberValue ?? 5)
        let results = searchApps(query: query, limit: limit)
        
        let resultArray = results.map { Self.appToJSON($0) }
        
        let summary = results.isEmpty 
            ? "No apps found matching '\(query)'."
            : "Found \(results.count) app\(results.count == 1 ? "" : "s")."
        
        return .success(
            .object(["results": .array(resultArray)]),
            summary: summary
        )
    }
    
    /// Minimum Jaro-Winkler score for fuzzy app name matching.
    static let fuzzyThreshold: Double = 0.80

    typealias AppInfo = (name: String, bundleId: String?, path: String)

    private func searchApps(query: String, limit: Int) -> [AppMatch] {
        let allApps = discoverApps()
        let lowercaseQuery = query.lowercased()

        // Primary path: substring contains (fast, exact)
        let substringResults = allApps.filter { $0.name.lowercased().contains(lowercaseQuery) }
        if !substringResults.isEmpty {
            return substringResults
                .prefix(limit)
                .map { AppMatch(name: $0.name, bundleId: $0.bundleId, path: $0.path, matchScore: nil) }
        }

        // Fallback: Jaro-Winkler fuzzy matching
        return fuzzyMatch(query: query, apps: allApps, limit: limit)
    }

    /// Scan standard app directories and return all discovered .app bundles.
    private func discoverApps() -> [AppInfo] {
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        var apps: [AppInfo] = []

        for basePath in searchPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
                continue
            }

            for item in contents where item.hasSuffix(".app") {
                let appName = (item as NSString).deletingPathExtension
                let fullPath = "\(basePath)/\(item)"
                let bundleId = Bundle(path: fullPath)?.bundleIdentifier
                apps.append((name: appName, bundleId: bundleId, path: fullPath))
            }
        }

        return apps
    }

    /// Score all apps against the query using Jaro-Winkler and return the best matches.
    static func fuzzyMatch(
        query: String,
        apps: [AppInfo],
        threshold: Double = fuzzyThreshold,
        limit: Int = 5
    ) -> [AppMatch] {
        apps
            .map { app in (app: app, score: StringSimilarity.jaroWinkler(query, app.name)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { AppMatch(name: $0.app.name, bundleId: $0.app.bundleId, path: $0.app.path, matchScore: $0.score) }
    }

    private func fuzzyMatch(
        query: String,
        apps: [AppInfo],
        limit: Int
    ) -> [AppMatch] {
        Self.fuzzyMatch(query: query, apps: apps, limit: limit)
    }

    static func appToJSON(_ match: AppMatch) -> JSONValue {
        var dict: [String: JSONValue] = [
            "name": .string(match.name),
            "bundle_id": .string(match.bundleId ?? ""),
            "path": .string(match.path)
        ]

        if let score = match.matchScore {
            dict["match_score"] = .number(Double(Int(score * 100)) / 100.0)
        }

        return .object(dict)
    }
}
