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
    
    private func searchApps(query: String, limit: Int) -> [(name: String, bundleId: String?, path: String)] {
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        
        var results: [(name: String, bundleId: String?, path: String)] = []
        let lowercaseQuery = query.lowercased()
        
        for basePath in searchPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
                continue
            }
            
            for item in contents where item.hasSuffix(".app") {
                let appName = (item as NSString).deletingPathExtension
                if appName.lowercased().contains(lowercaseQuery) {
                    let fullPath = "\(basePath)/\(item)"
                    let bundleId = Bundle(path: fullPath)?.bundleIdentifier
                    results.append((name: appName, bundleId: bundleId, path: fullPath))
                    
                    if results.count >= limit {
                        return results
                    }
                }
            }
        }
        
        return results
    }
}
