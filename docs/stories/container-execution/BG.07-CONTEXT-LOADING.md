# BG.07 - Context Loading

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** BG.04, BG.05
**Target:** macOS 26 (Tahoe)
**Design Reference:** BG.00

---

## 1. Objective

Allow Ora to load background task results into conversation context so the user can ask follow-up questions about research findings. Results are summarized before injection to respect the 6000-token context budget.

## 2. User Story

As a **user**, I want to **ask Ora about my research results** so that I can **have a conversation about the findings without leaving the app**.

## 3. Scope

### In Scope

- New tool: `research.load_result` (read-only, no confirmation needed)
- New tool: `research.list_results` (read-only, list available research artifacts)
- Load `summary.md` (preferred) or summarized `result.json` into conversation context
- Context-aware injection: summarize further if content would exceed remaining token budget
- Tool result includes key findings, source citations, and artifact path
- User can ask follow-up questions about loaded results

### Out of Scope

- Full-text search across artifacts
- Loading raw HTML or full `result.json` into context
- Embedding-based semantic retrieval
- Automatic context loading (user must explicitly ask)
- Multi-task synthesis ("combine results from task A and task B")

## 4. Architecture Alignment

### Component Placement

```
Ora/Tools/Research/
  ├── ResearchListResultsTool.swift     // List available research artifacts
  ├── ResearchLoadResultTool.swift      // Load result into conversation context
  └── ResearchStartTool.swift           // Trigger background task (BG.02 integration)
```

### Tool Definitions

**`research.list_results`**

| Property | Value |
|:---------|:------|
| Kind | `read` |
| Confirmation | No |
| Description | List available background research results |
| Parameters | `limit` (optional, default 10) |
| Returns | Array of `{taskId, title, date, status, summaryPreview}` |

**`research.load_result`**

| Property | Value |
|:---------|:------|
| Kind | `read` |
| Confirmation | No |
| Description | Load a research result into conversation context |
| Parameters | `task_id` (required) |
| Returns | Summary text, key findings, citations, artifact path |

**`research.start`** (registered here, dispatches to BackgroundTaskManager)

| Property | Value |
|:---------|:------|
| Kind | `read` (no confirmation — task is queued, not executed immediately) |
| Confirmation | No |
| Description | Start a background research task |
| Parameters | `urls` (required), `query` (optional) |
| Returns | `{taskId, status: "queued", message: "Research started..."}` |

### Context Injection Strategy

The current `ConversationManager` has a 6000-token budget (~20,000 characters). A typical `summary.md` is 300-500 words (~1500-2500 chars, ~450-750 tokens). This fits comfortably.

```
ConversationManager context budget: 6000 tokens
  - System prompt:    ~1500 tokens (tool schemas + instructions)
  - Conversation:     ~3000 tokens (user + assistant messages)
  - Available for     ~1500 tokens ← research result injected here
    tool results:
```

**Injection flow:**
```
1. LLM generates: {"type": "tool_call", "tool": "research.load_result", "args": {"task_id": "..."}}
2. ResearchLoadResultTool.execute():
   a. Read summary.md from artifact folder
   b. If summary.md > 1500 tokens (~5000 chars), truncate with "..." indicator
   c. Read citations.json for source references
   d. Return ToolResult with:
      - json: {summary, citations, artifactPath, wordCount}
      - humanSummary: "Loaded research on 'Swift concurrency' (3 sources, 450 words)"
3. AgentLoop adds tool result to conversation context
4. LLM generates follow-up response using the research data
```

### Existing Infrastructure Reused

| Component | Usage |
|:----------|:------|
| `Tool` protocol | `ResearchLoadResultTool` conforms to existing protocol |
| `ToolRegistry` | Register research tools in `registerDefaultTools()` |
| `ToolHost` | Execute via standard tool execution path |
| `ConversationManager` | Tool result added via `addToolResult()` |
| `ArtifactStore` (BG.04) | Read summary.md and result.json |
| `SystemPromptBuilder` | Add research tool schemas to system prompt |

### Guardrails

- Research tools are `read`-only: no confirmation needed, no state mutation
- Content injected as `tool_result` (untrusted data channel), not system prompt
- Truncation prevents context overflow
- Tool result clearly labeled with source (prevents LLM from treating it as instructions)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Research/ResearchListResultsTool.swift` — List available research artifacts
- `Ora/Tools/Research/ResearchLoadResultTool.swift` — Load summary + citations into context
- `Ora/Tools/Research/ResearchStartTool.swift` — Trigger background task (thin wrapper over BackgroundTaskManager)
- `OraTests/Tools/Research/ResearchToolsTests.swift` — Unit tests

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift` — Register `research.list_results`, `research.load_result`, `research.start`
- `Ora/Resources/system-prompt.txt` — Add research tool descriptions to available tools section

### 5.3 Tests to Add

- `OraTests/Tools/Research/ResearchToolsTests.swift`:
  - `test_listResults_returnsAvailableArtifacts`
  - `test_listResults_returnsEmptyWhenNoArtifacts`
  - `test_listResults_respectsLimit`
  - `test_loadResult_returnsSummaryAndCitations`
  - `test_loadResult_truncatesLongSummary`
  - `test_loadResult_throwsForInvalidTaskID`
  - `test_loadResult_throwsForMissingSummary`
  - `test_loadResult_fallsBackToResultJSON`
  - `test_startResearch_enqueuesTask`
  - `test_startResearch_validatesURLs`
  - `test_startResearch_rejectsEmptyURLs`

### 5.4 Dependencies/Config

- `project.yml` — Add `Ora/Tools/Research/` to sources

## 6. Acceptance Criteria

- [ ] AC-1: `research.list_results` returns available research artifacts with taskId, title, date, status
- [ ] AC-2: `research.load_result` loads `summary.md` content into conversation context
- [ ] AC-3: If `summary.md` exceeds ~5000 chars, it is truncated with indicator
- [ ] AC-4: Citations from `citations.json` included in tool result
- [ ] AC-5: If `summary.md` is missing, falls back to extractive summary from `result.json`
- [ ] AC-6: `research.start` enqueues a background task and returns task ID
- [ ] AC-7: User can ask follow-up questions about loaded research (LLM has context)
- [ ] AC-8: Research tools registered in `ToolRegistry` and schemas in system prompt
- [ ] AC-9: Tool results injected as untrusted data (not system prompt content)
- [ ] AC-10: Invalid task ID returns descriptive error (not crash)

## 7. Verification Plan

### Automated Tests

- [ ] Tool registration tests (all three research tools in registry)
- [ ] List results with mock artifact store
- [ ] Load result with mock summary.md (normal, long, missing)
- [ ] Start research with valid/invalid URL inputs
- [ ] Truncation boundary test (exactly at limit, over limit)

### Manual Tests

- [ ] Say "What research results do I have?" → verify list is spoken
- [ ] Say "Load the Swift concurrency research" → verify context loaded
- [ ] Ask follow-up "What did it say about actors?" → verify LLM answers from context
- [ ] Say "Research the latest SwiftUI changes" → verify task is queued
- [ ] Load a result, then ask about it → verify multi-turn conversation works

## 8. Performance / Reliability Considerations

- `research.list_results` reads only metadata (no file I/O for content); O(n) where n = artifact count
- `research.load_result` reads one file (~50KB max); negligible latency
- Context injection adds ~450-750 tokens; within budget with normal conversation
- No GPU usage (read-only tools); no impact on LLM/TTS performance

## 9. Risks & Mitigations

- **Context overflow** — Truncate summary to fit within remaining token budget. ConversationManager's FIFO trimming handles edge cases
- **Stale results** — Tool result includes `completedAt` timestamp; LLM can inform user if data is old
- **Missing artifacts** — Graceful error: "Research result not found. It may have been cleaned up." (not a crash)
- **Prompt injection via summary** — Summary was already generated by our LLM (BG.05); re-injection risk is low. Still treated as untrusted data in the tool_result channel

## 10. Open Questions

- Should `research.load_result` be triggered automatically when user asks about a topic with existing research? (Proposed: no — explicit tool call by LLM based on user request)
- Should we support loading multiple results into one conversation? (Proposed: yes, but each replaces the previous in context to avoid overflow)
- Should the LLM be able to decide which research to load based on conversation context? (Proposed: yes — LLM calls `research.list_results` first, then `research.load_result` with the relevant task ID)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
