# S.06 - Dynamic Tool Discovery (Client-Side)

**Epic:** Skills
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 5 days
**Dependencies:** S.01-SKILLS-RUNTIME (complete), S.00-CONTEXT-BUDGET (complete)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Anthropic Tool Search Tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)
**Last Updated:** February 26, 2026

---

## 1. Title and Summary

Ora currently registers 40 tools and injects all tool schemas into prompt context at session start. This story introduces provider-agnostic, client-side dynamic tool discovery so the agent carries only core schemas by default, discovers deferred schemas on demand via `tools.discover`, and keeps discovered schemas for the rest of the session. This follows Anthropic's recommended pattern for custom tools, while preserving Ora's existing local/cloud architecture, confirmation guardrails, and audit pipeline.

## 2. Architecture Context and Reuse Guidance

### Current architecture constraints

- Tool execution and guardrails already live in `ToolHost` and must stay the source of truth for validation, confirmation, and audit logging.
- Tool definitions come from `ToolRegistry.schemas()` and are currently injected once at `AgentLoop.startSession(...)`.
- `ConversationManager` currently supports `startConversation(systemPrompt:)`, but does not support in-place system prompt updates.
- Ora supports Local, OpenAI, and Anthropic providers through `LLMProviderManager`; tool discovery must remain provider-agnostic.

### Reuse decisions (do not reinvent)

- Reuse `ToolRegistry` actor as the single owner for tool metadata, discovery index, and per-session discovered sets.
- Reuse `ToolHost.executeWithAudit(...)` for `tools.discover` logging instead of adding a separate audit path.
- Reuse `SystemPromptBuilder` as the only formatter for tool prompt sections.
- Reuse existing unit test suites (`ToolRegistryTests`, `SystemPromptBuilderTests`, `AgentLoopTests`) and add focused discovery tests.

### Why this is client-side (not provider-native)

- Anthropic's `tool_search` is designed for Anthropic server tools; Ora tools are local/custom Swift tools.
- Ora's Anthropic/OpenAI providers are currently plain streaming text adapters and do not expose native provider tool-calling contracts.
- A provider-native path would create provider divergence and break local/cloud parity; this story intentionally avoids that.

## 3. Proposed Changes and Architecture Improvements

### 3.1 Add load policy on tools

- Add `ToolLoadPolicy` with `.core` and `.deferred`.
- Extend `Tool` protocol with `var loadPolicy: ToolLoadPolicy { get }` defaulting to `.deferred`.
- Mark the following as `.core`:
  - `calendar.query`
  - `contacts.search`
  - `reminders.list`
  - `system.open_app`
  - `mail.recent`
  - `tools.discover` (must be core so discovery is always reachable)

### 3.2 Add deterministic-first discovery index

- Add a lightweight `ToolDiscoveryIndex` (in-memory, Foundation-only) with:
  - Deterministic pass first: exact tool-name/domain/keyword matches.
  - BM25 fallback: rank by `name + description + parameter names`.
  - Configurable `topK` default 5, max 8.
- Build/rebuild index when default tools are registered.

### 3.3 Add `tools.discover` tool

- New read-only tool `tools.discover`.
- Input:
  - `query` (required)
  - `limit` (optional)
- Output:
  - top matches with full tool schemas (name, description, parameters, requiredParameters, requiresConfirmation).
  - short summary listing matched tool names for audit readability.
- Empty/blank query returns validation error.

### 3.4 Add session-scoped discovered schema cache

- Store discovered tool names per session in `ToolRegistry`.
- Session key source:
  - Use `AgentLoop` session id when present.
  - If external session id is nil, use an internal `toolDiscoverySessionID` created on session start.
- Clear discovered cache on `AgentLoop.endSession()`.

### 3.5 Refresh system prompt during loop (critical integration fix)

- Add `ConversationManager.updateSystemPrompt(_:)` to replace system prompt without clearing history.
- In `AgentLoop`, refresh prompt before each generation step using:
  - core schemas,
  - compact deferred catalog,
  - discovered schemas for current session.
- This ensures a just-discovered tool becomes available on the next loop step without restarting the session.

### 3.6 Update prompt instructions

- Update `Ora/Resources/system-prompt.txt`:
  - Instruct model to call `tools.discover` when needed tool is not in core/discovered sections.
  - Instruct model to avoid repeated discovery for already-discovered tools.
  - Keep confirmation rules unchanged.

### 3.7 Tool call budget behavior

- `tools.discover` should not consume the same budget as business tools.
- In `AgentLoop`, exclude `tools.discover` from `maxToolCallsPerTurn` counting to avoid premature budget exhaustion.

## 4. File Touch List (with rationale)

| File | Change | Why |
|:-----|:-------|:----|
| `Ora/Tools/ToolProtocol.swift` | Add `ToolLoadPolicy` and default `loadPolicy` | Tool-level classification lives with tool contract |
| `Ora/Tools/ToolRegistry.swift` | Add core/deferred filtering, discovery index, discovered cache APIs | Keep tool metadata/discovery in one actor |
| `Ora/Tools/ToolDiscoveryTool.swift` (new) | Implement `tools.discover` | Discovery entrypoint for the agent |
| `Ora/Orchestration/AgentLoop.swift` | Prompt refresh each loop step, session-scoped discovery key, budget exemption for `tools.discover` | Makes dynamic discovery actually effective |
| `Ora/LLM/ConversationManager.swift` | Add `updateSystemPrompt(_:)` | Allows in-place prompt updates |
| `Ora/LLM/SystemPromptBuilder.swift` | Add formatting for core/deferred/discovered sections | Prompt structure for dynamic loading |
| `Ora/Resources/system-prompt.txt` | Add discovery behavior rules | Model policy and behavior alignment |
| `Ora/Tools/Calendar/CalendarQueryTool.swift` | Mark `.core` | High-frequency core |
| `Ora/Tools/Contacts/ContactsSearchTool.swift` | Mark `.core` | High-frequency core |
| `Ora/Tools/Reminders/RemindersListTool.swift` | Mark `.core` | High-frequency core |
| `Ora/Tools/System/SystemOpenAppTool.swift` | Mark `.core` | High-frequency core |
| `Ora/Tools/Mail/MailRecentTool.swift` | Mark `.core` | High-frequency core |
| `OraTests/Tools/ToolRegistryTests.swift` | Add discovery/index/cache tests | Prevent ranking/cache regressions |
| `OraTests/LLM/SystemPromptBuilderTests.swift` | Add three-section prompt assertions | Prevent prompt-shape regressions |
| `OraTests/LLM/ConversationManagerTests.swift` | Add prompt update tests | Ensure history remains intact |
| `OraTests/Orchestration/AgentLoopTests.swift` | Add discover-then-execute and budget tests | Validate orchestration behavior |
| `OraTests/Tools/ToolDiscoveryTests.swift` (new) | Focused index + tool tests | Tight coverage for discovery mechanics |

## 5. Implementation Steps (ordered)

1. Extend `Tool` protocol with `loadPolicy`; default `.deferred`.
2. Mark the selected core tools and add new `tools.discover` tool.
3. Implement `ToolDiscoveryIndex` (deterministic-first + BM25 fallback) and wire it into `ToolRegistry`.
4. Add `ToolRegistry` APIs:
   - core schemas
   - deferred compact catalog rows
   - discovered schemas for session
   - discover-and-cache by query/session.
5. Add `ConversationManager.updateSystemPrompt(_:)`.
6. Update `SystemPromptBuilder` to emit:
   - Core tools (full schema)
   - Deferred catalog (compact one-line entries)
   - Discovered tools (full schema, session-scoped)
7. Update `AgentLoop`:
   - maintain tool-discovery session key,
   - rebuild/update prompt before each generation step,
   - exempt `tools.discover` from business tool-call budget.
8. Update system prompt instructions for discovery discipline.
9. Add tests and run full suite via `./build.sh test`.

## 6. Tests and Validation

### Automated

- New `ToolDiscoveryTests`:
  - index builds for deferred tools.
  - `"send a message"` ranks `messages.send` top-3.
  - `"search my files"` ranks `system.search_files` top-3.
  - blank query fails validation.
  - session cache accumulates discovered tools.
- `ToolRegistryTests`:
  - `schemas()` remains backward-compatible.
  - new filtered schema/catalog APIs return expected sets.
- `SystemPromptBuilderTests`:
  - three sections present.
  - deferred rows use compact format with confirmation indicator.
  - discovered section appears only when non-empty.
- `ConversationManagerTests`:
  - `updateSystemPrompt(_:)` preserves conversation messages.
- `AgentLoopTests`:
  - discover on step N enables deferred tool call on step N+1.
  - `tools.discover` does not exhaust `maxToolCallsPerTurn`.

### Manual

- `"open Spotify"` should call `system.open_app` without discovery.
- `"send a message to Mom"` should call `tools.discover` then `messages.send`.
- `"run my morning shortcut"` should call `tools.discover` then `system.run_shortcut`.
- Repeating a deferred-tool request in same session should not require repeated discovery.
- Verify logs with `./build.sh logs --category tools` and audit entries in Preferences.

## 7. Acceptance Criteria

- [x] AC-1: `ToolLoadPolicy` exists and all tools default to `.deferred` unless explicitly marked.
- [x] AC-2: Core tools are exactly: `calendar.query`, `contacts.search`, `reminders.list`, `system.open_app`, `mail.recent`, `tools.discover`.
- [x] AC-3: `ToolRegistry` builds and serves discovery index for deferred tools.
- [x] AC-4: `tools.discover` returns full schemas and caches discovered tool names per session.
- [x] AC-5: `tools.discover("send a message")` includes `messages.send` in top-3.
- [x] AC-6: `tools.discover("search my files")` includes `system.search_files` in top-3.
- [x] AC-7: `AgentLoop` refreshes prompt each generation step so discovered schemas are visible next step.
- [x] AC-8: Prompt output includes three sections: core full schemas, deferred compact catalog, discovered full schemas.
- [x] AC-9: `ConversationManager.updateSystemPrompt(_:)` updates system prompt without clearing non-system messages.
- [x] AC-10: `tools.discover` executions are audit-logged via existing `ToolHost` flow with query and matched names visible in parameters/summary.
- [x] AC-11: `tools.discover` does not consume business tool-call budget.
- [x] AC-12: Initial prompt tool block (core + deferred catalog, no discovered tools) is at most 45% of full-all-tools schema size baseline.
- [x] AC-13: `./build.sh test` passes with no regressions.

## 8. Risks and Open Questions

### Risks

- Discovery miss from ASR noise.
  - Mitigation: deterministic keyword aliases + BM25 fallback + clear failure summary.
- Overuse of discovery calls.
  - Mitigation: explicit prompt instruction and budget exemption only for `tools.discover`, not all read tools.
- Prompt churn due to per-step refresh.
  - Mitigation: refresh only when prompt content hash changes.

### Decisions

- Deferred catalog is grouped by domain (calendar, reminders, contacts, notes, messages, mail, system, skills), not alphabetically. Domain grouping improves model readability and mirrors how the system prompt already organizes context.
- `tools.discover` results include an optional numeric `score` (0.0–1.0) per match. Implementer must include this in the JSON output so the model can reason about match confidence when multiple candidates are close.

---

## Implementation Summary

**Date:** 2026-02-25
**Branch:** `feat/s06-tool-discovery`
**Commits:** 2 implementation commits
**Implemented by:** codex (complexity score: 10/10)
**Reviewed by:** Claude Code orchestrator (1 iteration)

### Files Changed
- `Ora/Tools/ToolProtocol.swift` — Added `ToolLoadPolicy` enum and `loadPolicy` protocol requirement
- `Ora/Tools/ToolDiscoveryIndex.swift` — New: deterministic-first + BM25 fallback discovery index
- `Ora/Tools/ToolDiscoveryTool.swift` — New: `tools.discover` tool implementation
- `Ora/Tools/ToolRegistry.swift` — Core/deferred filtering, discovery index, session cache APIs
- `Ora/Tools/Calendar/CalendarQueryTool.swift` — Marked `.core`
- `Ora/Tools/Contacts/ContactsSearchTool.swift` — Marked `.core`
- `Ora/Tools/Reminders/RemindersListTool.swift` — Marked `.core`
- `Ora/Tools/System/SystemOpenAppTool.swift` — Marked `.core`
- `Ora/Tools/Mail/MailRecentTool.swift` — Marked `.core`
- `Ora/LLM/ConversationManager.swift` — Added `updateSystemPrompt(_:)` for in-place updates
- `Ora/LLM/SystemPromptBuilder.swift` — Three-section prompt (core / deferred catalog / discovered)
- `Ora/Orchestration/AgentLoop.swift` — Prompt refresh per step, budget exemption for `tools.discover`
- `Ora/Resources/system-prompt.txt` — Discovery behavior instructions
- `OraTests/Tools/ToolDiscoveryTests.swift` — New: index, ranking, cache, validation tests
- `OraTests/Tools/ToolRegistryTests.swift` — Core/deferred filtering, discovery index tests
- `OraTests/LLM/SystemPromptBuilderTests.swift` — Three-section assertions, AC-12 baseline
- `OraTests/LLM/ConversationManagerTests.swift` — `updateSystemPrompt` history-preservation test
- `OraTests/Orchestration/AgentLoopTests.swift` — Discover-then-execute, budget exemption tests

## Code Review Findings

**Reviewed by:** Claude Code orchestrator
**Date:** 2026-02-25
**Iteration:** 1

### AC Coverage

| AC | Status |
|:---|:-------|
| AC-1: `ToolLoadPolicy` exists, defaults to `.deferred` | PASS |
| AC-2: Core tools exactly the specified 6 | PASS |
| AC-3: `ToolRegistry` builds discovery index for deferred tools | PASS |
| AC-4: `tools.discover` returns full schemas and caches per session | PASS |
| AC-5: `"send a message"` includes `messages.send` in top-3 | PASS |
| AC-6: `"search my files"` includes `system.search_files` in top-3 | PASS |
| AC-7: `AgentLoop` refreshes prompt each step for discovered tools | PASS |
| AC-8: Prompt has three sections: core, deferred, discovered | PASS |
| AC-9: `updateSystemPrompt(_:)` preserves conversation history | PASS |
| AC-10: `tools.discover` audit-logged with query and matched names | PASS |
| AC-11: `tools.discover` exempt from business tool-call budget | PASS |
| AC-12: Initial prompt ≤ 45% of full-all-tools baseline | PASS |
| AC-13: `./build.sh test` passes with no regressions (1462/1462) | PASS |

### Issues

**P0:** None
**P1:** None
**P2 (minor, non-blocking):**
- `ToolDiscoveryIndex` immutability is implicit (safe, but could use a comment)
- `tools.discover` outside AgentLoop uses throwaway UUID for session — acceptable by design

### Verdict

- [x] Ready for merge

## Completion Status

- [x] Implementation complete
- [x] Code review passed (1 iteration — codex flagged 1 P1 fix, applied and re-verified)
- [x] PR merged: https://github.com/benedict2310/ora/pull/162
- [x] Merged to main: `3767bd3`
- [x] Date: 2026-02-25
