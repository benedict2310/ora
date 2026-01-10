//
//  SystemOpenFolderSpecialTool.swift
//  Ora
//
//  Open well-known system folders
//

import Foundation
import AppKit

struct SystemOpenFolderSpecialTool: Tool {
    let name = "system.open_folder_special"
    let kind: ToolKind = .read
    
    private static let folderMap: [String: FileManager.SearchPathDirectory] = [
        "downloads": .downloadsDirectory,
        "desktop": .desktopDirectory,
        "documents": .documentDirectory,
        "applications": .applicationDirectory,
        "home": .userDirectory
    ]
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a well-known folder (downloads, desktop, documents, applications, home)",
            parameters: [
                "folder": ParameterSchema(type: "string", description: "Folder name: downloads, desktop, documents, applications, home")
            ],
            requiredParameters: ["folder"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let folder = args["folder"]?.stringValue, !folder.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: folder")
        }
        guard Self.folderMap.keys.contains(folder.lowercased()) else {
            throw ToolHostError.validationFailed(name, "folder must be one of: downloads, desktop, documents, applications, home")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let folder = args["folder"]?.stringValue?.lowercased() else {
            throw SystemToolError.invalidArgument("Folder name required")
        }

        let path: String
        if folder == "home" {
            path = NSHomeDirectory()
        } else if let searchPath = Self.folderMap[folder],
                  let url = FileManager.default.urls(for: searchPath, in: .userDomainMask).first {
            path = url.path
        } else {
            throw SystemToolError.notFound("Unknown folder: \(folder)")
        }

        let url = URL(fileURLWithPath: path)
        let success = await ExternalFocusTracker.shared.withExternalOperation {
            NSWorkspace.shared.open(url)
        }

        if success {
            return .success(
                .object(["opened": .bool(true), "path": .string(path)]),
                summary: "Opened \(folder.capitalized) folder."
            )
        } else {
            throw SystemToolError.failed("Failed to open \(folder) folder")
        }
    }
}
