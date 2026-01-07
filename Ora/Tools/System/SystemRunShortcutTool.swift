//
//  SystemRunShortcutTool.swift
//  Ora
//
//  Run user Shortcuts by name
//

import Foundation

struct SystemRunShortcutTool: Tool {
    let name = "system.run_shortcut"
    let kind: ToolKind = .mutate  // Requires confirmation
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Run a Shortcut by name. Requires confirmation.",
            parameters: [
                "name": ParameterSchema(type: "string", description: "Name of the Shortcut to run"),
                "input": ParameterSchema(type: "string", description: "Optional input to pass to the Shortcut")
            ],
            requiredParameters: ["name"],
            requiresConfirmation: true
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let shortcutName = args["name"]?.stringValue, !shortcutName.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: name")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let shortcutName = args["name"]?.stringValue else {
            throw SystemToolError.invalidArgument("Shortcut name required")
        }
        
        let input = args["input"]?.stringValue
        
        // Build command
        var arguments = ["run", shortcutName]
        if let input = input {
            arguments.append(contentsOf: ["-i", input])
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                return .success(
                    .object(["ran": .bool(true), "name": .string(shortcutName)]),
                    summary: "Ran \(shortcutName) shortcut."
                )
            } else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw SystemToolError.failed("Shortcut failed: \(errorMessage)")
            }
        } catch let error as SystemToolError {
            throw error
        } catch {
            throw SystemToolError.failed("Failed to run shortcut: \(error.localizedDescription)")
        }
    }
}
