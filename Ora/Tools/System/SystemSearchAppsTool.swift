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
        
        let resultArray = results.map { app in
            JSONValue.object([
                "name": .string(app.name),
                "bundle_id": .string(app.bundleId ?? ""),
                "path": .string(app.path)
            ])
        }
        
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

    private func searchApps(query: String, limit: Int) -> [(name: String, bundleId: String?, path: String)] {
        let allApps = discoverApps()
        let lowercaseQuery = query.lowercased()

        // Primary path: substring contains (fast, exact)
        let substringResults = allApps.filter { $0.name.lowercased().contains(lowercaseQuery) }
        if !substringResults.isEmpty {
            return Array(substringResults.prefix(limit))
        }

        // Fallback: Jaro-Winkler fuzzy matching
        return fuzzyMatch(query: query, apps: allApps, limit: limit)
    }

    /// Scan standard app directories and return all discovered .app bundles.
    private func discoverApps() -> [(name: String, bundleId: String?, path: String)] {
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        var apps: [(name: String, bundleId: String?, path: String)] = []

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
        apps: [(name: String, bundleId: String?, path: String)],
        threshold: Double = fuzzyThreshold,
        limit: Int = 5
    ) -> [(name: String, bundleId: String?, path: String)] {
        apps
            .map { app in (app: app, score: StringSimilarity.jaroWinkler(query, app.name)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.app }
    }

    private func fuzzyMatch(
        query: String,
        apps: [(name: String, bundleId: String?, path: String)],
        limit: Int
    ) -> [(name: String, bundleId: String?, path: String)] {
        Self.fuzzyMatch(query: query, apps: apps, limit: limit)
    }
}
