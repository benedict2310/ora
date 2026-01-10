//
//  SystemOpenPathTool.swift
//  Ora
//
//  Open files or folders with their default handler
//

import Foundation
import AppKit

struct SystemOpenPathTool: Tool {
    let name = "system.open_path"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a file or folder with its default handler",
            parameters: [
                "path": ParameterSchema(type: "string", description: "Path to file or folder")
            ],
            requiredParameters: ["path"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let path = args["path"]?.stringValue, !path.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: path")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let path = args["path"]?.stringValue else {
            throw SystemToolError.invalidArgument("Path required")
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SystemToolError.notFound("Path '\(path)'")
        }

        let success = await ExternalFocusTracker.shared.withExternalOperation {
            NSWorkspace.shared.open(url)
        }

        if success {
            let name = url.lastPathComponent
            return .success(
                .object(["opened": .bool(true), "path": .string(expandedPath)]),
                summary: "Opened \(name)."
            )
        } else {
            throw SystemToolError.failed("Failed to open path")
        }
    }
}
