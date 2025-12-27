# L.04 - System Prompt

**Epic:** LLM Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** L.01 (LLM Runtime)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Build dynamic system prompts with current date/time, timezone, available tools, and user preferences.

---

## 2. Implementation

**File:** `Ora/LLM/SystemPromptBuilder.swift`

```swift
//
//  SystemPromptBuilder.swift
//  Ora
//
//  Builds dynamic system prompts for LLM
//

import Foundation

/// Builds system prompts with dynamic context
struct SystemPromptBuilder {
    
    /// Build complete system prompt
    static func build(
        currentDate: Date = Date(),
        timezone: TimeZone = .current,
        defaultCalendar: String? = nil,
        tools: [ToolDefinition] = []
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        dateFormatter.timeZone = timezone
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.timeZone = timezone
        
        let toolsJSON = encodeToolSchemas(tools)
        
        return """
        You are Ora, a helpful voice assistant running locally on macOS. You help users manage their calendar, reminders, and contacts.
        
        CURRENT CONTEXT:
        - Date: \(dateFormatter.string(from: currentDate))
        - Time: \(timeFormatter.string(from: currentDate))
        - Timezone: \(timezone.identifier)
        - Default Calendar: \(defaultCalendar ?? "Default")
        
        CRITICAL OUTPUT RULES:
        1. You MUST respond with valid JSON only. No markdown, no explanations outside JSON.
        2. Every response must match one of these formats:
        
        For direct answers (no tool needed):
        {"type": "response", "text": "Your spoken response here"}
        
        For tool calls (read-only actions):
        {"type": "tool_call", "tool": "tool_name", "args": {...}}
        
        For proposals (mutations requiring confirmation):
        {"type": "proposal", "summary": "What will happen", "tool": "tool_name", "args": {...}}
        
        3. All dates/times in tool arguments MUST be ISO 8601 format with timezone.
           Example: "2025-12-27T14:30:00-08:00"
        
        4. If the user's request is ambiguous, ask for clarification using a response.
        
        5. Never execute mutations without first proposing them for confirmation.
        
        6. Keep responses concise - they will be spoken aloud.
        
        AVAILABLE TOOLS:
        \(toolsJSON)
        
        Remember: JSON only. No prose outside the JSON structure.
        """
    }
    
    /// Encode tool schemas for prompt
    private static func encodeToolSchemas(_ tools: [ToolDefinition]) -> String {
        if tools.isEmpty {
            return "No tools available."
        }
        
        var lines: [String] = []
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description)")
            if !tool.parameters.isEmpty {
                lines.append("  Parameters: \(tool.parameters.keys.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Tool definition for system prompt
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [String: String]  // name -> type description
    let requiresConfirmation: Bool
}
```

---

## 3. Acceptance Criteria

- [ ] **AC-1:** Current date/time included in prompt
- [ ] **AC-2:** Timezone correctly formatted
- [ ] **AC-3:** Tool schemas encoded in prompt
- [ ] **AC-4:** JSON output rules clearly stated
- [ ] **AC-5:** ISO 8601 date format documented

---

## 4. Implementation Checklist

- [ ] Create `SystemPromptBuilder.swift`
- [ ] Create `ToolDefinition` struct
- [ ] Test with various timezones
- [ ] Verify prompt fits within token budget
