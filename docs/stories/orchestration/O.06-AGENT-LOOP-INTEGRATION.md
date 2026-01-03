# O.06 - Agent Loop Integration

**Epic:** Orchestration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** O.02, O.03, X.02, L.04, F.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Wire AgentLoop into the main pipeline so structured tool reasoning runs end-to-end from the hotkey flow.

## 2. User Story

As a power user, I want my spoken requests to run through the agent loop so that Ora can execute calendar tools with confirmation and respond naturally.

## 3. Scope

### In Scope

- Route transcript processing through `AgentLoop` (no direct `LLMService.generate` in the main flow).
- Register default tools on app startup so tool schemas are available to the system prompt.
- Map `AgentResult` states to overlay/pipeline UI (thinking/responding/proposing/executing/speaking).
- Handle proposal confirm/deny notifications and execute tools on confirmation.
- Preserve per-session conversation context across follow-up turns.
- Use `ToolHost` audit logging for all tool executions.

### Out of Scope

- New tool implementations beyond Calendar (X.03-X.05).
- New confirmation UI/UX work (timeouts, diff previews, multi-call proposals).
- Streaming token UI for agent responses (StructuredGenerator is full-response only).
- Changes to TTS behavior or audio playback (covered by O.03/T.02).

### TTS Integration Notes (from O.03)

The O.03 story added TTS to `SimplePipelineController.handleCompletion()`. When implementing O.06:

1. **Response Flow:** After `AgentLoop.process()` returns `.response(text:)`, call the existing `speakResponse(_:)` method.
2. **Proposal Flow:** When `.proposal` is returned, do NOT start TTS until after confirmation and follow-up response generation.
3. **Error Flow:** On `.error`, show error in overlay (existing behavior) - no TTS needed for errors.
4. **Follow-up Response:** After `AgentLoop.executeConfirmedTool()` and `generateFollowUp()`, call `speakResponse()` with the follow-up text.

## 4. Architecture Alignment

- `SimplePipelineController` remains the `@MainActor` orchestrator; `AgentLoop` runs as an actor for reasoning/tool calls.
- Tools are registered via `ToolRegistry` and executed via `ToolHost` only (no direct EventKit usage in orchestrator).
- Confirmation follows the two-phase pattern: proposal -> user confirm -> execute (PRD UX Principle #4).
- System prompt built via `SystemPromptBuilder` with tool schemas; tool results added as tool messages only.
- Concurrency boundaries respected (UI updates on MainActor, tool calls async actors).

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None.

### 5.2 Files to Modify

- `Ora/AppDelegate.swift` - register default tools after setup completes.
- `Ora/Orchestration/SimplePipelineController.swift` - replace direct LLM path with `AgentLoop.process`, handle `.response`/`.proposal`/`.error`, manage proposal confirmation, and keep session context across follow-ups.
- `Ora/Orchestration/AgentLoop.swift` - add a session-aware entry point (avoid resetting conversation on every turn) and expose proposal info for UI.
- `Ora/Tools/ToolRegistry.swift` - optional `registerDefaultToolsIfNeeded` helper to avoid repeat registration.

### 5.3 Tests to Add

- `OraTests/Orchestration/SimplePipelineControllerTests.swift` - cover proposal handling (confirm/deny) with injected agent loop stub.
- `OraTests/Orchestration/AgentLoopTests.swift` - add coverage for session-aware processing (no reset on follow-up).
- `OraTests/Tools/ToolRegistryTests.swift` - ensure default tools registration is idempotent.

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: Hotkey flow uses `AgentLoop` for transcript processing (no direct LLM generation in the main flow).
- [ ] AC-2: Default tools are registered at startup and included in the system prompt tool list.
- [ ] AC-3: Read-only calendar tools execute automatically and return responses in the overlay.
- [ ] AC-4: Mutation proposals show the confirmation UI and no tool runs until confirmed.
- [ ] AC-5: Confirm executes the tool via `ToolHost`, logs the audit entry, and produces a follow-up response.
- [ ] AC-6: Deny cancels the proposal and returns to `.awaitingFollowUp` without executing.
- [ ] AC-7: Follow-up turns keep prior conversation context within the session.
- [ ] AC-8: Cancel during proposing/executing stops work and returns the pipeline to idle.
- [ ] AC-9: TTS speaks the response after `AgentLoop` returns `.response` (existing O.03 flow preserved).
- [ ] AC-10: TTS speaks the follow-up response after tool confirmation and `generateFollowUp()`.

## 7. Verification Plan

### Automated Tests

- [ ] SimplePipelineController proposal confirm/deny tests pass.
- [ ] AgentLoop session reuse tests pass.
- [ ] ToolRegistry default registration test passes.

### Manual Tests

- [ ] Ask "What's on my calendar tomorrow?" and see tool execution + response.
- [ ] Ask "Schedule a 30-minute meeting tomorrow at 3pm," confirm the proposal, and verify event creation + follow-up response.
- [ ] Repeat the request and press Cancel; verify no event created and UI returns to awaiting follow-up.
- [ ] Verify TTS speaks responses for both direct responses and post-confirmation follow-ups.

## 8. Performance / Reliability Considerations

- Preserve AgentLoop budgets (`maxStepsPerTurn`, `maxToolCallsPerTurn`, `maxTokensPerTurn`) to avoid runaway loops.
- Tool failures surface as assistant/tool error messages and the session continues.
- Keep UI responsive by running tool execution off the MainActor.

## 9. Risks & Mitigations

- Loss of token streaming for agent responses - show "Thinking/Responding" state and defer streaming to a later story.
- Conversation resets between turns - address via session-aware AgentLoop entry point.

## 10. Open Questions

- Should tool availability be gated by permissions (hide tools if Calendar access is denied)?
- Do we want a dedicated session object for audit correlation, or keep `sessionID` nil for now?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
