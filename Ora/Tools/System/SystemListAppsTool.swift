//
//  SystemListAppsTool.swift
//  Ora
//
//  List installed applications by category
//

import Foundation

struct SystemListAppsTool: Tool {
    let name = "system.list_apps"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List installed applications grouped by category (user, system, utility)",
            parameters: [
                "category": ParameterSchema(
                    type: "string",
                    description: "Filter by category: 'user', 'system', 'utility', or 'all' (default: 'all')"
                )
            ],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        if let category = args["category"]?.stringValue {
            let valid = ["user", "system", "utility", "all"]
            guard valid.contains(category.lowercased()) else {
                throw ToolHostError.validationFailed(
                    name,
                    "category must be one of: user, system, utility, all"
                )
            }
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let categoryFilter = args["category"]?.stringValue?.lowercased() ?? "all"
        let appsByCategory = scanApplications()
        
        var result: [String: JSONValue] = [:]
        var total = 0
        
        let categoriesToInclude: [String]
        if categoryFilter == "all" {
            categoriesToInclude = ["user", "system", "utility"]
        } else {
            categoriesToInclude = [categoryFilter]
        }
        
        for category in categoriesToInclude {
            if let apps = appsByCategory[category] {
                result[category] = .array(apps.map { .string($0) })
                total += apps.count
            }
        }
        
        result["total"] = .number(Double(total))
        
        let summary: String
        if categoryFilter == "all" {
            let userCount = appsByCategory["user"]?.count ?? 0
            let systemCount = appsByCategory["system"]?.count ?? 0
            let utilityCount = appsByCategory["utility"]?.count ?? 0
            summary = "Found \(total) apps: \(userCount) user, \(systemCount) system, \(utilityCount) utilities."
        } else {
            summary = "Found \(total) \(categoryFilter) apps."
        }
        
        return .success(.object(result), summary: summary)
    }
    
    private func scanApplications() -> [String: [String]] {
        var result: [String: [String]] = ["user": [], "system": [], "utility": []]
        
        let categories: [(path: String, category: String)] = [
            ("/Applications", "user"),
            (NSHomeDirectory() + "/Applications", "user"),
            ("/System/Applications", "system"),
            ("/System/Applications/Utilities", "utility")
        ]
        
        for (basePath, category) in categories {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
                continue
            }
            
            for item in contents where item.hasSuffix(".app") {
                let appName = (item as NSString).deletingPathExtension
                result[category]?.append(appName)
            }
        }
        
        // Sort each category alphabetically (case-insensitive)
        for category in result.keys {
            result[category]?.sort { $0.lowercased() < $1.lowercased() }
        }
        
        // Remove duplicates within each category (shouldn't happen but be safe)
        for category in result.keys {
            if let apps = result[category] {
                var seen = Set<String>()
                result[category] = apps.filter { app in
                    let lowercased = app.lowercased()
                    if seen.contains(lowercased) {
                        return false
                    }
                    seen.insert(lowercased)
                    return true
                }
            }
        }
        
        return result
    }
}
