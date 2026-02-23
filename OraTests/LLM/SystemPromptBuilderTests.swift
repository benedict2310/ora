//
//  SystemPromptBuilderTests.swift
//  OraTests
//
//  Unit tests for SystemPromptBuilder
//

import XCTest
@testable import Ora

final class SystemPromptBuilderTests: XCTestCase {
    
    // MARK: - Template Loading Tests
    
    func test_loadTemplate_returnsNonEmptyString() {
        let template = SystemPromptBuilder.loadTemplate()
        XCTAssertFalse(template.isEmpty, "Template should not be empty")
    }
    
    func test_loadTemplate_containsExpectedVariables() {
        let template = SystemPromptBuilder.loadTemplate()
        
        // Verify all expected variable placeholders are present
        XCTAssertTrue(template.contains("{{current_date}}"), "Template should contain {{current_date}}")
        XCTAssertTrue(template.contains("{{current_time}}"), "Template should contain {{current_time}}")
        XCTAssertTrue(template.contains("{{current_datetime_iso}}"), "Template should contain {{current_datetime_iso}}")
        XCTAssertTrue(template.contains("{{timezone}}"), "Template should contain {{timezone}}")
        XCTAssertTrue(template.contains("{{timezone_offset}}"), "Template should contain {{timezone_offset}}")
        XCTAssertTrue(template.contains("{{default_calendar}}"), "Template should contain {{default_calendar}}")
        XCTAssertTrue(template.contains("{{tools}}"), "Template should contain {{tools}}")
        XCTAssertTrue(template.contains("{{available_skills}}"), "Template should contain {{available_skills}}")
    }
    
    func test_loadTemplate_containsOraIdentity() {
        let template = SystemPromptBuilder.loadTemplate()
        XCTAssertTrue(template.contains("Ora"), "Template should mention Ora")
    }
    
    // MARK: - Variable Resolution Tests
    
    func test_resolveVariables_replacesCurrentDate() {
        let template = "Today is {{current_date}}"
        let date = createTestDate(year: 2025, month: 12, day: 27)
        let timezone = TimeZone(identifier: "America/Los_Angeles")!
        
        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: date,
            timezone: timezone,
            defaultCalendar: nil,
            tools: []
        )
        
        // Check the variable was replaced (contains a formatted date)
        XCTAssertFalse(result.contains("{{current_date}}"), "Variable should be replaced")
        XCTAssertTrue(result.contains("December"), "Date should contain month name")
        XCTAssertTrue(result.contains("2025"), "Date should contain year")
    }
    
    func test_resolveVariables_replacesCurrentTime() {
        let template = "Time is {{current_time}}"
        let date = createTestDate(year: 2025, month: 12, day: 27, hour: 14, minute: 30)
        let timezone = TimeZone(identifier: "America/Los_Angeles")!
        
        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: date,
            timezone: timezone,
            defaultCalendar: nil,
            tools: []
        )
        
        XCTAssertTrue(result.contains("2:30 PM"), "Time should be formatted correctly")
        XCTAssertFalse(result.contains("{{current_time}}"), "Variable should be replaced")
    }
    
    func test_resolveVariables_replacesTimezone() {
        let template = "Zone: {{timezone}}"
        let timezone = TimeZone(identifier: "America/New_York")!
        
        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: Date(),
            timezone: timezone,
            defaultCalendar: nil,
            tools: []
        )
        
        XCTAssertTrue(result.contains("America/New_York"), "Timezone should be included")
        XCTAssertFalse(result.contains("{{timezone}}"), "Variable should be replaced")
    }

    func test_resolveVariables_replacesTimezoneOffset() {
        let template = "Offset: {{timezone_offset}}"
        let timezone = TimeZone(identifier: "America/New_York")!
        let date = createTestDate(year: 2025, month: 12, day: 27, hour: 10, minute: 0)

        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: date,
            timezone: timezone,
            defaultCalendar: nil,
            tools: []
        )

        XCTAssertTrue(result.contains("UTC"), "Timezone offset should be included")
        XCTAssertFalse(result.contains("{{timezone_offset}}"), "Variable should be replaced")
    }

    func test_resolveVariables_replacesCurrentDateTimeISO() {
        let template = "Now: {{current_datetime_iso}}"
        let timezone = TimeZone(identifier: "America/Los_Angeles")!
        let date = createTestDate(year: 2025, month: 12, day: 27, hour: 14, minute: 30)

        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: date,
            timezone: timezone,
            defaultCalendar: nil,
            tools: []
        )

        XCTAssertTrue(result.contains("T"), "ISO datetime should contain T separator")
        XCTAssertFalse(result.contains("{{current_datetime_iso}}"), "Variable should be replaced")
    }
    
    func test_resolveVariables_replacesDefaultCalendar() {
        let template = "Calendar: {{default_calendar}}"
        
        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: Date(),
            timezone: .current,
            defaultCalendar: "Work",
            tools: []
        )
        
        XCTAssertTrue(result.contains("Work"), "Calendar name should be included")
        XCTAssertFalse(result.contains("{{default_calendar}}"), "Variable should be replaced")
    }
    
    func test_resolveVariables_usesDefaultForNilCalendar() {
        let template = "Calendar: {{default_calendar}}"
        
        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: Date(),
            timezone: .current,
            defaultCalendar: nil,
            tools: []
        )
        
        XCTAssertTrue(result.contains("Default"), "Should use 'Default' when calendar is nil")
    }
    
    func test_resolveVariables_replacesToolsWithEmptyList() {
        let template = "Tools: {{tools}}"
        
        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: Date(),
            timezone: .current,
            defaultCalendar: nil,
            tools: []
        )
        
        XCTAssertTrue(result.contains("No tools available"), "Should show 'No tools available' for empty list")
        XCTAssertFalse(result.contains("{{tools}}"), "Variable should be replaced")
    }
    
    func test_resolveVariables_replacesToolsWithDefinitions() {
        let template = "{{tools}}"
        let tools = [
            ToolDefinition(
                name: "calendar.list",
                description: "List all calendars",
                parameters: [:],
                requiresConfirmation: false
            ),
            ToolDefinition(
                name: "calendar.create",
                description: "Create an event",
                parameters: ["title": "string", "start": "date"],
                requiredParameters: ["title", "start"],
                requiresConfirmation: true
            )
        ]
        
        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: Date(),
            timezone: .current,
            defaultCalendar: nil,
            tools: tools
        )
        
        XCTAssertTrue(result.contains("calendar.list"), "Should include first tool name")
        XCTAssertTrue(result.contains("calendar.list: List all calendars"), "Should include compact read-only line")
        XCTAssertTrue(result.contains("calendar.create"), "Should include second tool name")
        XCTAssertTrue(result.contains("calendar.create[confirm]"), "Should indicate confirmation requirement")
        XCTAssertTrue(result.contains("title:str*"), "Should mark required params with *")
        XCTAssertTrue(result.contains("start:datetime*"), "Should abbreviate date types")
    }

    func test_resolveVariables_replacesAvailableSkillsBlock() {
        let template = "{{available_skills}}"
        let skills = [
            SkillMetadata(
                id: "daily-briefing",
                name: "Daily Briefing",
                description: "Morning summary workflow",
                source: .bundled,
                rootURL: URL(fileURLWithPath: "/tmp/daily-briefing", isDirectory: true),
                version: "1.0.0"
            )
        ]

        let result = SystemPromptBuilder.resolveVariables(
            in: template,
            currentDate: Date(),
            timezone: .current,
            defaultCalendar: nil,
            tools: [],
            skills: skills
        )

        XCTAssertTrue(result.contains("<available_skills>"))
        XCTAssertTrue(result.contains("skill id=\"daily-briefing\""))
        XCTAssertTrue(result.contains("<description>Morning summary workflow</description>"))
    }
    
    // MARK: - Build Tests
    
    func test_build_producesCompletePrompt() {
        let date = createTestDate(year: 2025, month: 12, day: 27, hour: 14, minute: 30)
        let timezone = TimeZone(identifier: "America/Los_Angeles")!
        
        let prompt = SystemPromptBuilder.build(
            currentDate: date,
            timezone: timezone,
            defaultCalendar: "Personal",
            tools: []
        )
        
        // Verify no unresolved variables remain (check for {{ that's not in JSON examples)
        // The template contains JSON examples with {}, so we check for {{ specifically
        let unresolvedPattern = "\\{\\{[a-z_]+\\}\\}"
        let regex = try? NSRegularExpression(pattern: unresolvedPattern)
        let range = NSRange(prompt.startIndex..., in: prompt)
        let matches = regex?.numberOfMatches(in: prompt, range: range) ?? 0
        XCTAssertEqual(matches, 0, "Should not contain unresolved variables")
        
        // Verify dynamic content is present
        XCTAssertTrue(prompt.contains("December"), "Should contain month from date")
        XCTAssertTrue(prompt.contains("2025"), "Should contain year")
        XCTAssertTrue(prompt.contains("America/Los_Angeles"), "Should contain timezone")
        XCTAssertTrue(prompt.contains("Personal"), "Should contain calendar name")
    }
    
    func test_build_withDefaultParameters() {
        let prompt = SystemPromptBuilder.build()
        
        // Should produce a valid prompt with defaults
        XCTAssertFalse(prompt.isEmpty, "Should produce non-empty prompt")
        XCTAssertTrue(prompt.contains("Ora"), "Should mention Ora")
        
        // Check for unresolved variables using regex (allows {} in JSON examples)
        let unresolvedPattern = "\\{\\{[a-z_]+\\}\\}"
        let regex = try? NSRegularExpression(pattern: unresolvedPattern)
        let range = NSRange(prompt.startIndex..., in: prompt)
        let matches = regex?.numberOfMatches(in: prompt, range: range) ?? 0
        XCTAssertEqual(matches, 0, "Should not contain unresolved variables")
    }
    
    // MARK: - Tool Encoding Tests
    
    func test_encodeToolSchemas_emptyList() {
        let result = SystemPromptBuilder.encodeToolSchemas([])
        XCTAssertEqual(result, "No tools available.")
    }
    
    func test_encodeToolSchemas_singleToolNoParams() {
        let tools = [
            ToolDefinition(
                name: "test.tool",
                description: "A test tool",
                parameters: [:],
                requiresConfirmation: false
            )
        ]
        
        let result = SystemPromptBuilder.encodeToolSchemas(tools)
        
        XCTAssertEqual(result, "test.tool: A test tool")
        XCTAssertFalse(result.contains("["), "Tools with no parameters should omit parameter block")
    }
    
    func test_encodeToolSchemas_usesCompactSingleLineFormat() {
        let tools = [
            ToolDefinition(
                name: "alpha.read",
                description: "Read alpha data.",
                parameters: ["query": "string"],
                requiredParameters: ["query"],
                requiresConfirmation: false
            ),
            ToolDefinition(
                name: "beta.write",
                description: "Write beta data. Requires confirmation.",
                parameters: ["enabled": "boolean"],
                requiredParameters: ["enabled"],
                requiresConfirmation: true
            )
        ]

        let result = SystemPromptBuilder.encodeToolSchemas(tools)
        let lines = result.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 2, "Should emit one line per tool")
        XCTAssertFalse(result.hasSuffix("\n"), "Should not end with trailing blank lines")
        XCTAssertEqual(lines[0], "alpha.read: Read alpha data [query:str*]")
        XCTAssertEqual(lines[1], "beta.write[confirm]: Write beta data [enabled:bool*]")
    }

    func test_encodeSkillsMetadata_emptyList_returnsEmptyString() {
        XCTAssertEqual(SystemPromptBuilder.encodeSkillsMetadata([]), "")
    }

    func test_encodeSkillsMetadata_escapesXMLReservedCharacters() {
        let skills = [
            SkillMetadata(
                id: "ops&qa",
                name: "Ops <QA>",
                description: "Use \"safe\" checks & outputs",
                source: .user,
                rootURL: URL(fileURLWithPath: "/tmp/ops-qa", isDirectory: true),
                version: nil
            )
        ]

        let result = SystemPromptBuilder.encodeSkillsMetadata(skills)
        XCTAssertTrue(result.contains("id=\"ops&amp;qa\""))
        XCTAssertTrue(result.contains("name=\"Ops &lt;QA&gt;\""))
        XCTAssertTrue(result.contains("<description>Use &quot;safe&quot; checks &amp; outputs</description>"))
    }

    func test_encodeToolSchemas_marksRequiredAndUsesTypeAbbreviations() {
        let tools = [
            ToolDefinition(
                name: "types.demo",
                description: "Type mapping.",
                parameterSchemas: [
                    "when": ToolParameterDefinition(type: "string", format: "date-time"),
                    "count": ToolParameterDefinition(type: "number"),
                    "flag": ToolParameterDefinition(type: "boolean"),
                    "tags": ToolParameterDefinition(type: "array<string>"),
                    "title": ToolParameterDefinition(type: "string")
                ],
                requiredParameters: ["when", "title"],
                requiresConfirmation: false
            )
        ]

        let result = SystemPromptBuilder.encodeToolSchemas(tools)

        XCTAssertEqual(
            result,
            "types.demo: Type mapping [count:int, flag:bool, tags:str[], title:str*, when:datetime*]"
        )
    }

    func test_encodeToolSchemas_defaultToolSet_containsAllToolNamesAndStaysCompact() async {
        let tools = await self.loadDefaultToolDefinitions()
        let result = SystemPromptBuilder.encodeToolSchemas(tools)
        let lines = result.components(separatedBy: "\n")

        XCTAssertEqual(tools.count, 40, "Expected current default registry to expose 40 tools")
        XCTAssertEqual(lines.count, tools.count, "Should emit one non-empty line per tool")
        XCTAssertTrue(lines.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "No blank lines allowed")
        XCTAssertLessThanOrEqual(result.count, 3_800, "Compact tool block should remain within budget")

        for tool in tools {
            XCTAssertNotNil(self.encodedLine(for: tool.name, in: result), "Missing tool line for \(tool.name)")
        }
    }

    func test_encodeToolSchemas_defaultToolSet_confirmMarkerMatchesMutatingTools() async {
        let tools = await self.loadDefaultToolDefinitions()
        let result = SystemPromptBuilder.encodeToolSchemas(tools)

        for tool in tools {
            guard let line = self.encodedLine(for: tool.name, in: result) else {
                XCTFail("Missing encoded line for \(tool.name)")
                continue
            }

            if tool.requiresConfirmation {
                XCTAssertTrue(line.hasPrefix("\(tool.name)[confirm]:"), "Mutating tool must include [confirm]")
            } else {
                XCTAssertTrue(line.hasPrefix("\(tool.name):"), "Read-only tool must omit [confirm]")
                XCTAssertFalse(line.hasPrefix("\(tool.name)[confirm]:"), "Read-only tool must omit [confirm]")
            }
        }
    }

    func test_build_withDefaultToolSet_producesValidNonEmptyPromptWithAllTools() async {
        let tools = await self.loadDefaultToolDefinitions()
        let prompt = SystemPromptBuilder.build(tools: tools)

        XCTAssertFalse(prompt.isEmpty)
        for tool in tools {
            XCTAssertTrue(prompt.contains(tool.name), "Prompt should include \(tool.name)")
        }
    }
    
    // MARK: - Fallback Template Tests
    
    func test_fallbackTemplate_containsVariables() {
        let fallback = SystemPromptBuilder.fallbackTemplate
        
        XCTAssertTrue(fallback.contains("{{current_date}}"), "Fallback should contain date variable")
        XCTAssertTrue(fallback.contains("{{current_time}}"), "Fallback should contain time variable")
        XCTAssertTrue(fallback.contains("{{timezone}}"), "Fallback should contain timezone variable")
    }
    
    func test_fallbackTemplate_canBeResolved() {
        let fallback = SystemPromptBuilder.fallbackTemplate
        
        let result = SystemPromptBuilder.resolveVariables(
            in: fallback,
            currentDate: Date(),
            timezone: .current,
            defaultCalendar: nil,
            tools: []
        )
        
        XCTAssertFalse(result.contains("{{"), "Fallback should be fully resolvable")
    }
    
    // MARK: - Helpers

    private func encodedLine(for toolName: String, in encoded: String) -> String? {
        encoded
            .components(separatedBy: "\n")
            .first { line in
                line.hasPrefix("\(toolName):") || line.hasPrefix("\(toolName)[confirm]:")
            }
    }

    private func loadDefaultToolDefinitions() async -> [ToolDefinition] {
        let registry = ToolRegistry.makeTestInstance()
        await registry.registerDefaultTools()
        let schemas = await registry.schemas()

        return schemas.map { schema in
            ToolDefinition(
                name: schema.name,
                description: schema.description,
                parameterSchemas: schema.parameters.mapValues { parameter in
                    ToolParameterDefinition(type: parameter.type, format: parameter.format)
                },
                requiredParameters: schema.requiredParameters,
                requiresConfirmation: schema.requiresConfirmation
            )
        }
    }
    
    private func createTestDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        
        return Calendar.current.date(from: components)!
    }
}
