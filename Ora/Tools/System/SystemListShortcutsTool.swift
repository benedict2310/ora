//
//  SystemListShortcutsTool.swift
//  Ora
//
//  List available Shortcuts
//

import Foundation

struct SystemListShortcutsTool: Tool {
    let name = "system.list_shortcuts"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List available Shortcuts",
            parameters: [:],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        // No parameters required
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            let shortcuts = output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            let resultArray = shortcuts.map { JSONValue.string($0) }
            
            return .success(
                .object(["shortcuts": .array(resultArray), "count": .number(Double(shortcuts.count))]),
                summary: "Found \(shortcuts.count) shortcut\(shortcuts.count == 1 ? "" : "s")."
            )
        } catch {
            throw SystemToolError.failed("Failed to list shortcuts: \(error.localizedDescription)")
        }
    }
}
