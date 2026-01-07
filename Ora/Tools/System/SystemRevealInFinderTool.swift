//
//  SystemRevealInFinderTool.swift
//  Ora
//
//  Reveal a file in Finder (select it)
//

import Foundation
import AppKit

struct SystemRevealInFinderTool: Tool {
    let name = "system.reveal_in_finder"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Reveal a file in Finder and select it",
            parameters: [
                "path": ParameterSchema(type: "string", description: "Path to file to reveal")
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
            throw SystemToolError.notFound("File '\(path)'")
        }
        
        NSWorkspace.shared.activateFileViewerSelecting([url])
        
        let name = url.lastPathComponent
        return .success(
            .object(["revealed": .bool(true), "path": .string(expandedPath)]),
            summary: "Revealed \(name) in Finder."
        )
    }
}
