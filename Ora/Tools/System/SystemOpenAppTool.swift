//
//  SystemOpenAppTool.swift
//  Ora
//
//  Open applications by bundle ID or name
//

import Foundation
import AppKit

struct SystemOpenAppTool: Tool {
    let name = "system.open_app"
    let kind: ToolKind = .read  // No confirmation needed
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open an application by bundle ID or name",
            parameters: [
                "bundle_id": ParameterSchema(type: "string", description: "Bundle identifier (e.g., 'com.apple.Safari')"),
                "app_name": ParameterSchema(type: "string", description: "Application name (e.g., 'Safari', 'Spotify')")
            ],
            requiredParameters: [],  // At least one must be provided
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        let bundleId = args["bundle_id"]?.stringValue
        let appName = args["app_name"]?.stringValue
        
        guard (bundleId != nil && !bundleId!.isEmpty) || (appName != nil && !appName!.isEmpty) else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: bundle_id or app_name")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let workspace = NSWorkspace.shared
        
        // Try bundle ID first
        if let bundleId = args["bundle_id"]?.stringValue, !bundleId.isEmpty {
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
                let alreadyRunning = workspace.runningApplications.contains { $0.bundleIdentifier == bundleId }
                let config = NSWorkspace.OpenConfiguration()
                try await workspace.openApplication(at: appURL, configuration: config)
                return .success(
                    .object([
                        "opened": .bool(true),
                        "bundle_id": .string(bundleId),
                        "path": .string(appURL.path),
                        "already_running": .bool(alreadyRunning)
                    ]),
                    summary: "Opened \(appURL.deletingPathExtension().lastPathComponent)."
                )
            }
        }
        
        // Try app name
        if let appName = args["app_name"]?.stringValue, !appName.isEmpty {
            if let appURL = findAppByName(appName) {
                let bundleId = Bundle(url: appURL)?.bundleIdentifier
                let alreadyRunning = bundleId.map { id in
                    workspace.runningApplications.contains { $0.bundleIdentifier == id }
                } ?? false
                
                let config = NSWorkspace.OpenConfiguration()
                try await workspace.openApplication(at: appURL, configuration: config)
                return .success(
                    .object([
                        "opened": .bool(true),
                        "bundle_id": .string(bundleId ?? ""),
                        "path": .string(appURL.path),
                        "already_running": .bool(alreadyRunning)
                    ]),
                    summary: "Opened \(appName)."
                )
            }
            
            throw SystemToolError.notFound("Application '\(appName)'")
        }
        
        throw SystemToolError.invalidArgument("Bundle ID or app name required")
    }
    
    private func findAppByName(_ name: String) -> URL? {
        let workspace = NSWorkspace.shared
        
        // Check running apps first
        if let app = workspace.runningApplications.first(where: { 
            $0.localizedName?.lowercased() == name.lowercased() 
        }) {
            return app.bundleURL
        }
        
        // Search common locations
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        
        for basePath in searchPaths {
            let directPath = URL(fileURLWithPath: "\(basePath)/\(name).app")
            if FileManager.default.fileExists(atPath: directPath.path) {
                return directPath
            }
            
            // Fuzzy search in directory
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: nil
            ) {
                if let match = contents.first(where: {
                    $0.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased()
                }) {
                    return match
                }
            }
        }
        
        return nil
    }
}
