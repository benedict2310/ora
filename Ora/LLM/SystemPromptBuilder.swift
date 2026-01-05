//
//  SystemPromptBuilder.swift
//  Ora
//
//  Builds dynamic system prompts for LLM by loading a template file
//  and resolving variables at runtime.
//

import Foundation
import os

/// Builds system prompts with dynamic context from a template file
///
/// The template file is stored at `Ora/Resources/system-prompt.txt` and uses
/// `{{variable_name}}` syntax for placeholders that are resolved at runtime.
///
/// ## Supported Variables
/// - `{{current_date}}` - Current date (e.g., "Friday, December 27, 2025")
/// - `{{current_time}}` - Current time (e.g., "2:30 PM")
/// - `{{timezone}}` - Timezone identifier (e.g., "America/Los_Angeles")
/// - `{{default_calendar}}` - User's default calendar name
/// - `{{tools}}` - Available tool descriptions
///
struct SystemPromptBuilder {
    
    // MARK: - Properties
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "SystemPromptBuilder")
    
    /// The template filename (without path)
    static let templateFilename = "system-prompt.txt"
    
    // MARK: - Public API
    
    /// Build complete system prompt with dynamic values
    /// - Parameters:
    ///   - currentDate: The current date/time (defaults to now)
    ///   - timezone: The timezone to use (defaults to current)
    ///   - defaultCalendar: User's default calendar name
    ///   - tools: Available tool definitions
    /// - Returns: The resolved system prompt string
    static func build(
        currentDate: Date = Date(),
        timezone: TimeZone = .current,
        defaultCalendar: String? = nil,
        tools: [ToolDefinition] = []
    ) -> String {
        let template = loadTemplate()
        return resolveVariables(
            in: template,
            currentDate: currentDate,
            timezone: timezone,
            defaultCalendar: defaultCalendar,
            tools: tools
        )
    }
    
    /// Load and return the raw template without variable resolution
    /// - Returns: The template string
    static func loadTemplate() -> String {
        // Try to load from bundle
        guard let url = Bundle.main.url(forResource: "system-prompt", withExtension: "txt") else {
            logger.error("System prompt template not found in bundle")
            return fallbackTemplate
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            logger.debug("Loaded system prompt template (\(content.count) chars)")
            return content
        } catch {
            logger.error("Failed to load system prompt template: \(error.localizedDescription)")
            return fallbackTemplate
        }
    }
    
    /// Load template from a specific URL (for testing)
    /// - Parameter url: URL to load from
    /// - Returns: The template string or nil if loading fails
    static func loadTemplate(from url: URL) -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error("Failed to load template from \(url): \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Variable Resolution
    
    /// Resolve all variables in the template
    static func resolveVariables(
        in template: String,
        currentDate: Date,
        timezone: TimeZone,
        defaultCalendar: String?,
        tools: [ToolDefinition]
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        dateFormatter.timeZone = timezone
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.timeZone = timezone
        
        var result = template
        
        // Resolve each variable
        result = result.replacingOccurrences(of: "{{current_date}}", with: dateFormatter.string(from: currentDate))
        result = result.replacingOccurrences(of: "{{current_time}}", with: timeFormatter.string(from: currentDate))
        result = result.replacingOccurrences(of: "{{timezone}}", with: timezone.identifier)
        result = result.replacingOccurrences(of: "{{default_calendar}}", with: defaultCalendar ?? "Default")
        result = result.replacingOccurrences(of: "{{tools}}", with: encodeToolSchemas(tools))
        
        return result
    }
    
    // MARK: - Tool Encoding
    
    /// Encode tool schemas for the prompt
    static func encodeToolSchemas(_ tools: [ToolDefinition]) -> String {
        if tools.isEmpty {
            return "No tools available."
        }

        var lines: [String] = []
        for tool in tools {
            let accessLabel = tool.requiresConfirmation ? "Requires confirmation" : "Read-only"
            lines.append("- \(tool.name) (\(accessLabel)): \(tool.description)")
            if !tool.parameters.isEmpty {
                let params = tool.parameters.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                lines.append("  Parameters: \(params)")
            }
        }
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Fallback
    
    /// Fallback template if file cannot be loaded
    static let fallbackTemplate = """
    You are Ora, a helpful voice assistant running locally on macOS.
    
    CURRENT CONTEXT:
    - Date: {{current_date}}
    - Time: {{current_time}}
    - Timezone: {{timezone}}
    
    Respond with valid JSON only.
    """
}

// MARK: - Tool Definition

/// Tool definition for system prompt
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [String: String]  // name -> type description
    let requiresConfirmation: Bool
    
    init(
        name: String,
        description: String,
        parameters: [String: String] = [:],
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
    }
}
