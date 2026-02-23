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
/// - `{{current_datetime_iso}}` - Current date/time in ISO 8601 format with timezone
/// - `{{timezone}}` - Timezone identifier (e.g., "America/Los_Angeles")
/// - `{{timezone_offset}}` - Timezone offset (e.g., "UTC-08:00")
/// - `{{default_calendar}}` - User's default calendar name
/// - `{{tools}}` - Available tool descriptions
/// - `{{available_skills}}` - Available skills metadata in XML
///
struct SystemPromptBuilder {
    
    // MARK: - Properties
    
    private static let logger = Logger.ora(category: "SystemPromptBuilder")
    
    /// The template filename (without path)
    static let templateFilename = "system-prompt.txt"
    
    // MARK: - Public API
    
    /// Build complete system prompt with dynamic values
    /// - Parameters:
    ///   - currentDate: The current date/time (defaults to now)
    ///   - timezone: The timezone to use (defaults to current)
    ///   - defaultCalendar: User's default calendar name
    ///   - tools: Available tool definitions
    ///   - skills: Available skill metadata
    /// - Returns: The resolved system prompt string
    static func build(
        currentDate: Date = Date(),
        timezone: TimeZone = .current,
        defaultCalendar: String? = nil,
        tools: [ToolDefinition] = [],
        skills: [SkillMetadata] = []
    ) -> String {
        let template = loadTemplate()
        return resolveVariables(
            in: template,
            currentDate: currentDate,
            timezone: timezone,
            defaultCalendar: defaultCalendar,
            tools: tools,
            skills: skills
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
        tools: [ToolDefinition],
        skills: [SkillMetadata] = []
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        dateFormatter.timeZone = timezone
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.timeZone = timezone
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        isoFormatter.timeZone = timezone
        
        var result = template
        
        // Resolve each variable
        result = result.replacingOccurrences(of: "{{current_date}}", with: dateFormatter.string(from: currentDate))
        result = result.replacingOccurrences(of: "{{current_time}}", with: timeFormatter.string(from: currentDate))
        result = result.replacingOccurrences(of: "{{current_datetime_iso}}", with: isoFormatter.string(from: currentDate))
        result = result.replacingOccurrences(of: "{{timezone}}", with: timezone.identifier)
        result = result.replacingOccurrences(of: "{{timezone_offset}}", with: formatUTCOffset(for: timezone, date: currentDate))
        result = result.replacingOccurrences(of: "{{default_calendar}}", with: defaultCalendar ?? "Default")
        result = result.replacingOccurrences(of: "{{tools}}", with: encodeToolSchemas(tools))
        result = result.replacingOccurrences(of: "{{available_skills}}", with: encodeSkillsMetadata(skills))
        
        return result
    }
    
    // MARK: - Tool Encoding
    
    /// Encode tool schemas for the prompt
    static func encodeToolSchemas(_ tools: [ToolDefinition]) -> String {
        if tools.isEmpty {
            return "No tools available."
        }

        let sortedTools = tools.sorted { $0.name < $1.name }
        let lines = sortedTools.map { tool in
            var line = "\(tool.name)"
            if tool.requiresConfirmation {
                line += "[confirm]"
            }

            line += ": \(compactDescription(tool.description))"

            let parameterString = encodeParameterList(for: tool)
            if !parameterString.isEmpty {
                line += " [\(parameterString)]"
            }

            return line
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
    - Time (ISO 8601): {{current_datetime_iso}}
    - Timezone: {{timezone}}
    
    Respond with valid JSON only.
    """

    static func encodeSkillsMetadata(_ skills: [SkillMetadata]) -> String {
        guard !skills.isEmpty else {
            return ""
        }

        let sortedSkills = skills.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        var lines: [String] = ["<available_skills>"]
        for skill in sortedSkills {
            let id = xmlEscaped(skill.id)
            let name = xmlEscaped(skill.name)
            let description = xmlEscaped(skill.description)

            lines.append("  <skill id=\"\(id)\" name=\"\(name)\">")
            lines.append("    <description>\(description)</description>")
            lines.append("  </skill>")
        }
        lines.append("</available_skills>")

        return lines.joined(separator: "\n")
    }

    private static func formatUTCOffset(for timezone: TimeZone, date: Date) -> String {
        let seconds = timezone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        return String(format: "UTC%@%02d:%02d", sign, hours, minutes)
    }

    private static func encodeParameterList(for tool: ToolDefinition) -> String {
        guard !tool.parameters.isEmpty else {
            return ""
        }

        let orderedNames = tool.parameters.keys.sorted()
        return orderedNames.compactMap { name in
            guard let parameter = tool.parameters[name] else {
                return nil
            }

            let shortType = abbreviatedType(type: parameter.type, format: parameter.format)
            let requiredSuffix = tool.requiredParameters.contains(name) ? "*" : ""
            return "\(name):\(shortType)\(requiredSuffix)"
        }
        .joined(separator: ", ")
    }

    private static func abbreviatedType(type: String, format: String?) -> String {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedFormat = format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedFormat == "date-time" {
            return "datetime"
        }

        if normalizedType == "date" || normalizedType == "datetime" {
            return "datetime"
        }

        if normalizedType == "number" || normalizedType == "integer" || normalizedType == "int" {
            return "int"
        }

        if normalizedType == "boolean" || normalizedType == "bool" {
            return "bool"
        }

        if normalizedType == "string[]" ||
            normalizedType == "[string]" ||
            normalizedType == "array<string>" ||
            normalizedType == "array[string]" ||
            normalizedType == "array_of_strings" ||
            (normalizedType.contains("array") && normalizedType.contains("string")) {
            return "str[]"
        }

        return "str"
    }

    private static func compactDescription(_ description: String) -> String {
        var compact = normalizeWhitespace(description)
        compact = compact.replacingOccurrences(
            of: "Requires confirmation.",
            with: "",
            options: .caseInsensitive
        )
        compact = compact.replacingOccurrences(
            of: "Requires confirmation",
            with: "",
            options: .caseInsensitive
        )
        compact = normalizeWhitespace(compact)

        if let sentenceEnd = compact.firstIndex(of: ".") {
            compact = String(compact[..<sentenceEnd])
        }

        compact = compact.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
        if compact.count > 52 {
            compact = String(compact.prefix(52))
            if let lastSpace = compact.lastIndex(of: " ") {
                compact = String(compact[..<lastSpace])
            }
        }

        return compact.isEmpty ? "execute tool" : compact
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Tool Definition

struct ToolParameterDefinition: Sendable {
    let type: String
    let format: String?

    init(type: String, format: String? = nil) {
        self.type = type
        self.format = format
    }

    init(schemaDescriptor: String) {
        let descriptor = schemaDescriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = descriptor.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let parsedType = components.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let fallbackType = parsedType.isEmpty ? descriptor : parsedType

        var parsedFormat: String?
        if let openIndex = descriptor.lastIndex(of: "("),
           let closeIndex = descriptor.lastIndex(of: ")"),
           openIndex < closeIndex {
            let formatStart = descriptor.index(after: openIndex)
            parsedFormat = String(descriptor[formatStart..<closeIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        self.type = fallbackType.isEmpty ? "string" : fallbackType
        self.format = parsedFormat
    }
}

/// Tool definition for system prompt
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [String: ToolParameterDefinition]
    let requiredParameters: Set<String>
    let requiresConfirmation: Bool
    
    init(
        name: String,
        description: String,
        parameters: [String: String] = [:],
        requiredParameters: [String] = [],
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters.mapValues { ToolParameterDefinition(schemaDescriptor: $0) }
        self.requiredParameters = Set(requiredParameters)
        self.requiresConfirmation = requiresConfirmation
    }

    init(
        name: String,
        description: String,
        parameterSchemas: [String: ToolParameterDefinition],
        requiredParameters: [String] = [],
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameterSchemas
        self.requiredParameters = Set(requiredParameters)
        self.requiresConfirmation = requiresConfirmation
    }
}
