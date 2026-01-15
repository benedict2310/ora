# UX.01 - Agent Transparency Status

**Epic:** UX
**Status:** Open
**Priority:** P1 (High)
**Estimated Effort:** 2-3 days
**Dependencies:** O.03, O.06, F.10
**Target:** macOS 26 (Tahoe)
**Design Reference:** F.10 Liquid Glass Overlay Refresh

---

## 1. Objective

Expose what the agent is doing between listening and responding so users can trust progress and understand tool usage.

## 2. User Story

As a power or accessibility user, I want the overlay to explain what Ora is doing (planning, calling tools, composing) so I know the assistant is making progress.

## 3. Scope

### In Scope

- Add a lightweight activity/status layer for the agentic loop.
- Show tool-specific activity (e.g., "Checking calendar", "Writing reminder").
- Update activity during streaming responses and follow-up waits.
- Respect Reduce Motion and Reduce Transparency.
- Keep the existing overlay mode state machine intact.

### Out of Scope

- Tool behavior changes or new tools.
- Chain-of-thought or verbose reasoning text.
- Audit log UI changes.

## 4. Architecture Alignment

- `OverlayMode` remains the primary state machine.
- `OverlayActivity` is a secondary, UI-only signal derived from orchestrator/agent loop events.
- Agent loop emits activity updates via delegate callbacks; no UI-driven tool calls.

## 5. Implementation Plan

### 5.1 Files to Modify

- `Ora/Overlay/OverlayState.swift`: add `OverlayActivity` enum and `@Published var activity`.
- `Ora/Overlay/OverlayView.swift`: surface activity text near `VoiceInputControlView` or as a compact status chip.
- `Ora/Overlay/VoiceInputControlView.swift`: allow optional activity subtitle (if used for the status line).
- `Ora/Orchestration/AgentLoop.swift`: emit activity updates for planning/tool calls/result/composing.
- `Ora/Orchestration/SimplePipelineController.swift`: map activity events to overlay updates, set activity for speaking/waiting, and clear on reset.

### 5.2 Agent Activity Events

- Add `AgentActivity` enum:
  - `planning`
  - `toolCall(name: String)`
  - `toolResult(name: String)`
  - `composing`
  - `waiting`
- Extend `AgentLoopDelegate` with `agentLoop(_:didUpdateActivity:)`.
- Emit:
  - `planning` before each generation step.
  - `toolCall` before tool execution.
  - `toolResult` after tool execution result is added to context.
  - `composing` when response tokens begin streaming.
  - `waiting` when awaiting follow-up.

### 5.3 UI Mapping

- Listening: "Listening"
- Thinking/planning: "Planning response"
- Tool call: "Calling <Tool Name>"
- Tool result: "Processing <Tool Name> result"
- Responding: "Composing response"
- Speaking: "Speaking"
- Awaiting follow-up: "Waiting for your reply"

Tool label mapping:
- calendar.* -> "Calendar"
- reminders.* -> "Reminders"
- contacts.* -> "Contacts"
- system.run_shortcut/system.list_shortcuts -> "Shortcuts"
- system.* -> "System"
- fallback -> "Tool"

### 5.4 Tests

- `OraTests/Overlay/OverlayActivityTests.swift`: verify activity label mapping.
- `OraTests/Orchestration/AgentLoopActivityTests.swift`: verify activity events fire in expected order for tool calls.

## 6. Acceptance Criteria

- AC-1: Activity label updates during agent loop steps without blocking the pipeline.
- AC-2: Tool-related activity includes a user-friendly tool label using the mapping table.
- AC-3: Activity clears when overlay resets or hides.
- AC-4: Reduce Motion/Transparency keep activity text legible and stable.
- AC-5: Activity updates never trigger tool execution or state mutation.
- AC-6: Non-tool responses show at least planning -> composing -> speaking.

## 7. Verification Plan

### Automated

- Run `./build.sh test`.

### Manual

- Hotkey press shows "Listening".
- Submit transcript shows "Planning response" then "Composing response".
- Tool flow shows "Calling <Tool>" and "Processing <Tool> result".
- Speaking shows "Speaking", then "Waiting for your reply".
- Toggle Reduce Motion/Transparency.

## 8. Risks & Mitigations

- Risk: Rapid updates cause flicker. Mitigation: debounce activity changes and keep labels short.
- Risk: Tool names are too technical. Mitigation: add a friendly mapping table.

## 9. Open Questions

- Should the activity label live inside the voice input control or as a separate status chip above the chat stack?
