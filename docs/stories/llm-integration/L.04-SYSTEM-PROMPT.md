# L.04 - System Prompt

**Epic:** LLM Integration
**Status:** Complete
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** L.01 (LLM Runtime)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Build dynamic system prompts with current date/time, timezone, available tools, and user preferences. The system prompt should be stored in an editable file for easy iteration without code changes.

---

## 2. Implementation

### Files Created

**Template File:** `Ora/Resources/system-prompt.txt`
- Editable text file bundled with the app
- Uses `{{variable}}` syntax for placeholders
- Can be modified without changing code

**Builder:** `Ora/LLM/SystemPromptBuilder.swift`
- Loads template from bundle
- Resolves all variable placeholders
- Provides fallback if template not found

**Tests:** `OraTests/LLM/SystemPromptBuilderTests.swift`
- 17 unit tests for loading and variable resolution

### Supported Variables

| Variable | Example Output |
|:---------|:---------------|
| `{{current_date}}` | Friday, December 27, 2025 |
| `{{current_time}}` | 2:30 PM |
| `{{timezone}}` | America/Los_Angeles |
| `{{default_calendar}}` | Personal (or "Default" if nil) |
| `{{tools}}` | Formatted list of available tools |

### Usage

```swift
// Build with current context
let prompt = SystemPromptBuilder.build(
    currentDate: Date(),
    timezone: .current,
    defaultCalendar: "Work",
    tools: availableTools
)

// Load raw template (for debugging)
let template = SystemPromptBuilder.loadTemplate()

// Resolve variables manually
let resolved = SystemPromptBuilder.resolveVariables(
    in: template,
    currentDate: date,
    timezone: timezone,
    defaultCalendar: calendar,
    tools: tools
)
```

---

## 3. Acceptance Criteria

- [x] **AC-1:** Current date/time included in prompt - ✅ `{{current_date}}` and `{{current_time}}` resolved
- [x] **AC-2:** Timezone correctly formatted - ✅ `{{timezone}}` uses `TimeZone.identifier`
- [x] **AC-3:** Tool schemas encoded in prompt - ✅ `{{tools}}` formatted with `encodeToolSchemas()`
- [x] **AC-4:** JSON output rules clearly stated - ✅ Template includes CRITICAL OUTPUT RULES section
- [x] **AC-5:** ISO 8601 date format documented - ✅ Template includes example format

---

## 4. Implementation Checklist

- [x] Create `SystemPromptBuilder.swift`
- [x] Create `ToolDefinition` struct
- [x] Create editable `system-prompt.txt` template
- [x] Test with various timezones
- [x] Verify prompt fits within token budget (~1200 chars base)
- [x] Add 17 unit tests

---

## Implementation Plan

### Files to Create
- `Ora/Resources/system-prompt.txt` - Editable template file
- `Ora/LLM/SystemPromptBuilder.swift` - Template loader and variable resolver
- `OraTests/LLM/SystemPromptBuilderTests.swift` - Unit tests

### Files to Modify
- `project.yml` - Add Resources directory as bundled resources
- `AGENTS.md` - Document system prompt location

---

## Implementation Summary

**Date:** 2025-12-31
**Branch:** main (direct commit)
**Commit:** 958a1d8

### Files Changed
- `Ora/Resources/system-prompt.txt` - Created: Editable system prompt template
- `Ora/LLM/SystemPromptBuilder.swift` - Created: Template loading and variable resolution
- `OraTests/LLM/SystemPromptBuilderTests.swift` - Created: 17 unit tests
- `project.yml` - Modified: Added Resources as bundled resources
- `AGENTS.md` - Modified: Added Key Resources section

### Key Implementation Details
1. **File-based template:** System prompt stored in `Ora/Resources/system-prompt.txt`
2. **Variable syntax:** Uses `{{variable_name}}` placeholders
3. **Fallback template:** Built-in fallback if file loading fails
4. **Tool encoding:** Formats tool definitions with name, description, parameters, and confirmation requirement
5. **Swift 6 compliant:** No mutable static state, thread-safe

### Test Coverage
All 17 SystemPromptBuilder tests pass:
- Template loading: 3 tests
- Variable resolution: 7 tests
- Build methods: 2 tests
- Tool encoding: 3 tests
- Fallback template: 2 tests

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (17/17)
- [x] Build successful

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2025-12-31T16:40:12Z
**Commit reviewed:** 16bf2dc
**Iteration:** 1

### Summary
- Files reviewed: 7
- Build status: Pass
- Tests status: Fail (534 tests, 1 failure, 1 skipped)

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None

#### P2 - Minor (Can defer)
- [ ] `Ora/LLM/SystemPromptBuilder.swift:99` - Date/time formatting uses the current locale; tests and prompt assume English strings, so output can vary or fail on non-English locales. Consider setting a fixed locale (e.g., `en_US_POSIX`) or loosening assertions in `OraTests/LLM/SystemPromptBuilderTests.swift:53`.

### Future Considerations (Out of Scope)
- `OraTests/AudioServiceTests.swift:265` - `AudioServiceTests.test_start_requires_microphone_permission()` failed during `xcodebuild test` (permission-dependent), not related to this change.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
