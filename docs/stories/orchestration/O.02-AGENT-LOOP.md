# O.02 - Agent Loop

**Epic:** Orchestration
**Status:** Open
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** L.01 (LLM), L.02 (Structured Output), X.01 (Tool Protocol), O.01 (ASR-LLM Pipeline)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement the core agentic reasoning loop that processes user requests, calls tools, and generates responses.

**Note:** O.01 uses a simplified conversational prompt for testing. This story reintroduces the full structured system prompt with JSON output format and tool definitions.

---

## 2. Prerequisites from O.01

The SimplePipelineController currently uses a simple conversational prompt:
```swift
let systemPrompt = """
You are Ora, a helpful voice assistant running locally on macOS.
...
Respond naturally and conversationally.
"""
```

This story must:
1. Replace the simple prompt with `SystemPromptBuilder.build(tools: ...)` 
2. Parse structured JSON responses using `StructuredGenerator`
3. Handle tool calls, proposals, and plain responses

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AgentLoop                             │
│                         (Actor)                              │
├─────────────────────────────────────────────────────────────┤
│  1. Receive user text                                       │
│  2. Build messages with system prompt                       │
│  3. Generate structured LLM response                        │
│  4. Parse response type (text/tool_call/proposal)          │
│  5. If tool: validate, execute (with confirmation)         │
│  6. Add tool result to context                             │
│  7. Repeat until response or budget exhausted              │
│  8. Return final response                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

**File:** `Ora/Orchestration/AgentLoop.swift`

See the actual implementation in the source file for the complete code.

---

## 4. Acceptance Criteria

- [x] **AC-1:** Reintroduce `SystemPromptBuilder.build(tools:)` with tool definitions - ✅ Verified in `AgentLoop.swift:109-121`
- [x] **AC-2:** Processes user text through LLM with structured JSON output - ✅ Verified by test `test_process_simpleResponse_returnsResponseResult`
- [x] **AC-3:** Parses response/tool_call/proposal types from JSON - ✅ Verified by tests for each type
- [x] **AC-4:** Executes read-only tools automatically - ✅ Verified by test `test_process_toolCall_executesAndContinues`
- [x] **AC-5:** Returns proposals for mutations (requiring confirmation) - ✅ Verified by test `test_process_proposal_returnsProposalResult`
- [x] **AC-6:** Respects step and tool call limits (6 steps, 3 tool calls max) - ✅ Verified by tests `test_process_stepBudgetExhausted_returnsError` and `test_process_toolCallLimit_returnsError`
- [x] **AC-7:** Adds tool results to conversation context - ✅ Verified in `AgentLoop.swift:221-222`
- [x] **AC-8:** Generates follow-up response after tool execution - ✅ Verified by test `test_generateFollowUp_returnsResponse`

---

## 5. Implementation Checklist

- [x] Create `AgentLoop.swift` actor
- [ ] Update SimplePipelineController or create new orchestrator to use AgentLoop (future story)
- [x] Reintroduce `SystemPromptBuilder.build(tools:)` with registered tool schemas
- [x] Integrate with StructuredGenerator for JSON parsing
- [x] Integrate with ToolHost for tool execution
- [x] Integrate with ConversationManager for context
- [x] Handle the three response types: response, tool_call, proposal
- [x] Test multi-step reasoning (tool → result → follow-up)
- [x] Test budget limits (max steps, max tool calls)
- [x] Test error handling and graceful degradation

---

## Implementation Summary

**Date:** 2026-01-02
**Branch:** `feat/O.02-agent-loop`

### Files Created
- `Ora/Orchestration/AgentLoop.swift` - Core agentic reasoning loop actor
- `OraTests/Orchestration/AgentLoopTests.swift` - Comprehensive test suite (10 tests)

### Files Modified
- `Ora/Tools/ToolRegistry.swift` - Added `makeTestInstance()` factory for testing

### Key Design Decisions

1. **Actor-based design:** `AgentLoop` is an actor for thread-safe state management
2. **Dependency injection:** All dependencies (StructuredGenerator, ToolHost, ToolRegistry, ConversationManager) are injectable for testing
3. **MainActor delegate:** The delegate protocol is `@MainActor` isolated for safe UI updates
4. **Policy limits:** 6 steps max, 3 tool calls max per turn to prevent runaway loops
5. **Graceful degradation:** Tool failures are added to context rather than terminating the loop

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (10/10 AgentLoop tests)
- [x] Working tree clean

---

## Code Review Findings

**Reviewer:** Manual Review (after subagent timeout)
**Date:** 2026-01-02T15:20:00Z
**Commit reviewed:** cd71c0f
**Iteration:** 1

### Summary
- Files reviewed: 4 (AgentLoop.swift, ToolRegistry.swift, ToolProtocol.swift, AgentLoopTests.swift)
- Build status: Pass
- Tests status: Pass (19 tests including AgentLoop, ToolHost, ToolRegistry)

### Issues Found

#### P0 - Critical (Must fix)

*None*

#### P1 - Major (Should fix)

- [x] `AgentLoop.swift:109-121` - **FIXED** The `requiresConfirmation` logic was using name-based heuristics (`schema.name.contains("create")`) instead of the tool's actual `kind` property. This could cause mutation tools to execute without confirmation if they don't follow naming conventions. Fixed by adding `requiresConfirmation` to `ToolSchema` and deriving it from the `Tool.kind` property.

#### P2 - Minor (Can defer)

- [ ] `AgentLoop.swift:52` - The `maxTokensPerTurn` property is unused. Consider either implementing token counting or removing this property.

### Future Considerations (Out of Scope)

- Integration with SimplePipelineController is deferred to O.03 story
- Pre-existing test failures in HuggingFaceDownloaderTests (network-dependent tests)

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Completion Status

- [x] Implementation complete
- [x] Code review passed (1 iteration)
- [x] PR merged: https://github.com/benedict2310/ora/pull/27
- [x] Merged to main: a7ebf9c
- [x] Date: 2026-01-02
- Reopened: 2026-01-05 (stale branch review; see `docs/reports/branch-merge-status-2026-01-05.md`)
