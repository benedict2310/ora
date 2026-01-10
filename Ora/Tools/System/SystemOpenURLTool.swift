//
//  SystemOpenURLTool.swift
//  Ora
//
//  Open URLs in default browser
//

import Foundation
import AppKit

struct SystemOpenURLTool: Tool {
    let name = "system.open_url"
    let kind: ToolKind = .read  // No confirmation needed
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a URL in the default browser",
            parameters: [
                "url": ParameterSchema(type: "string", description: "URL to open", format: "uri")
            ],
            requiredParameters: ["url"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let urlString = args["url"]?.stringValue, !urlString.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: url")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let urlString = args["url"]?.stringValue else {
            throw SystemToolError.invalidArgument("URL required")
        }

        // Normalize URL - add https:// if no scheme
        var normalizedURLString = urlString
        if !urlString.contains("://") {
            normalizedURLString = "https://\(urlString)"
        }

        guard let url = URL(string: normalizedURLString) else {
            throw SystemToolError.invalidArgument("Invalid URL: \(urlString)")
        }

        let success = await ExternalFocusTracker.shared.withExternalOperation {
            NSWorkspace.shared.open(url)
        }

        if success {
            return .success(
                .object(["opened": .bool(true), "url": .string(url.absoluteString)]),
                summary: "Opened \(url.host ?? urlString) in your browser."
            )
        } else {
            throw SystemToolError.failed("Failed to open URL")
        }
    }
}
