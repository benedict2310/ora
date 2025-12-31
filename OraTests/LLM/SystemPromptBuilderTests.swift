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
        XCTAssertTrue(template.contains("{{timezone}}"), "Template should contain {{timezone}}")
        XCTAssertTrue(template.contains("{{default_calendar}}"), "Template should contain {{default_calendar}}")
        XCTAssertTrue(template.contains("{{tools}}"), "Template should contain {{tools}}")
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
        XCTAssertTrue(result.contains("List all calendars"), "Should include first tool description")
        XCTAssertTrue(result.contains("calendar.create"), "Should include second tool name")
        XCTAssertTrue(result.contains("Requires confirmation"), "Should indicate confirmation requirement")
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
        
        XCTAssertTrue(result.contains("test.tool"), "Should contain tool name")
        XCTAssertTrue(result.contains("A test tool"), "Should contain description")
        XCTAssertFalse(result.contains("Parameters"), "Should not mention parameters when empty")
        XCTAssertFalse(result.contains("confirmation"), "Should not mention confirmation when not required")
    }
    
    func test_encodeToolSchemas_toolWithParamsAndConfirmation() {
        let tools = [
            ToolDefinition(
                name: "calendar.create",
                description: "Create an event",
                parameters: ["title": "string"],
                requiresConfirmation: true
            )
        ]
        
        let result = SystemPromptBuilder.encodeToolSchemas(tools)
        
        XCTAssertTrue(result.contains("Parameters:"), "Should mention parameters")
        XCTAssertTrue(result.contains("title"), "Should include parameter name")
        XCTAssertTrue(result.contains("Requires confirmation"), "Should indicate confirmation requirement")
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
