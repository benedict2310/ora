# S.06 - Tool Discovery

**Epic:** Skills
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 4 days
**Dependencies:** S.01 (Skills Runtime — complete)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Anthropic Tool Search Tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)

---

## 1. Objective

Ora currently loads all 40 tool schemas into the LLM context on every turn. This is already past the empirically measured degradation threshold (~30–50 tools) at which tool selection accuracy drops significantly. As new integrations land (BG series, C series, S.03 skill scripts, S.05 agent-authored tools), this will only worsen.

This story introduces a **two-tier tool loading model**:

1. **Core tools** — a small set (~5) of high-frequency, read-only tools whose full schemas are always injected into the system prompt.
2. **Deferred tools** — all other tools; they appear only as a compact one-line catalog in the prompt. The agent calls `tools.discover` to fetch full schemas for whichever deferred tools it needs, and discovered schemas persist for the remainder of the session.

The discovery index is built at startup using BM25 ranking over tool names, descriptions, and parameter names via the existing `Memory/HybridScorer.swift` infrastructure.

**Urgency:** With 40 tools already registered, this is a present-day problem, not a future concern.

## 2. User Story

As Ora, when the user makes a request that requires a less-common tool (e.g., sending a message, running a Shortcut, searching files), I want to discover the relevant tool schema on demand rather than carrying all 40 schemas in every prompt, so that my context budget stays focused on the conversation and my tool selection accuracy stays high.

As a developer, I want each tool to declare its own load policy (core vs. deferred) alongside its existing schema, so the classification lives where the tool is defined and is easy to audit.

## 3. Scope

### In Scope

- `ToolLoadPolicy` enum (`.core` / `.deferred`) added to `Tool` protocol with a default of `.deferred`
- Core tools annotated with `.core`: `CalendarQueryTool`, `ContactsSearchTool`, `RemindersListTool`, `SkillsListTool`, `SystemOpenAppTool`
- BM25 index built at startup in `ToolRegistry` from all deferred tool schemas (name + description + parameter names concatenated as corpus)
- `ToolDiscoveryTool` (`tools.discover`): accepts a `query` string, returns full schemas for top-5 deferred tool matches
- `SystemPromptBuilder` change: injects full schemas for core tools + a compact `[name]: [one-line description]` catalog for deferred tools under a `## Available Tools (search with tools.discover)` heading
- Discovered schemas injected into the assistant context and cached for the session in `ConversationManager`
- Audit logging of every `tools.discover` call (query, matches surfaced, session ID)
- Token budget estimate logged at startup (core schema tokens + compact catalog tokens)
- Tests: BM25 index correctness, top-N retrieval, session cache behaviour, schema injection format

### Out of Scope

- Embedding/vector-based retrieval (BM25 is sufficient at current scale; revisit at 100+ tools)
- Dynamic tool registration after startup
- Changing the `Tool` protocol's `execute`/`validate` contracts
- Per-user tool preference or ranking
- UI surface for the discovery catalog
- Removing any existing tools

## 4. Architecture Alignment

### Component Boundaries

```
┌─────────────────────────────────────────────────────────────────┐
│                       ToolRegistry (actor)                      │
├─────────────────────────────────────────────────────────────────┤
│  coreTools: [any Tool]         — always in system prompt        │
│  deferredTools: [any Tool]     — in compact catalog             │
│  bm25Index: ToolBM25Index      — built at registerDefaultTools  │
│  discoveredSchemas: SessionCache — per-session discovered set   │
└─────────────────────────────────────────────────────────────────┘
         │ search(query:topK:)
         ▼
┌─────────────────────────────────────────────────────────────────┐
│  ToolDiscoveryTool  (kind: .read, name: "tools.discover")       │
│  — BM25 query → top-5 ToolSchemas → JSON result                 │
│  — adds discovered schemas to session cache                      │
└─────────────────────────────────────────────────────────────────┘
         │ full schemas for session
         ▼
┌─────────────────────────────────────────────────────────────────┐
│  SystemPromptBuilder                                            │
│  — encodeToolSchemas(coreTools) → full schemas block            │
│  — encodeCompactCatalog(deferredTools) → catalog block          │
│  — encodeToolSchemas(sessionDiscovered) → discovered block      │
└─────────────────────────────────────────────────────────────────┘
```

### Concurrency Model

- `ToolRegistry` is already an `actor`; `bm25Index` and `discoveredSchemas` live inside it — no new concurrency primitives needed.
- `ToolDiscoveryTool.execute` calls `await ToolRegistry.shared.search(...)` from inside the existing async tool execution flow.
- Session cache is keyed by `Session.id` and cleared on `ConversationManager.reset()`.

### BM25 Index Details

`ToolBM25Index` is a lightweight struct (not `HybridScorer` directly — that's tied to SwiftData memory retrieval). It implements the same BM25 formula using only `Foundation`:

- **Corpus document per tool:** `"\(tool.name) \(tool.schema.description) \(tool.schema.parameters.keys.joined(separator: " "))"`
- **Parameters:** k1 = 1.5, b = 0.75 (standard defaults)
- **Index built once** at `registerDefaultTools()` completion; O(n) build, O(n) per query at n=40–100 tools (negligible)
- No external dependencies, no on-disk persistence

### System Prompt Format

```
## Core Tools
[full schema block — same format as today]

## Available Tools (use tools.discover to load full schema)
tools.discover: Search and load schemas for additional tools
calendar.create_event[⚠]: Create a new calendar event
calendar.edit_event[⚠]: Edit an existing calendar event
...

## Discovered Tools (this session)
[full schemas for tools discovered via tools.discover — grows during session]
```

`[⚠]` marks tools that require confirmation, preserving the existing guardrails signal.

### Guardrails & Audit Logging

- `ToolDiscoveryTool` is `kind: .read` — no confirmation required.
- Every call is audit-logged: `{ tool: "tools.discover", query: "...", matches: ["...", ...], sessionId: "..." }`.
- Discovered schemas never bypass confirmation gates on the underlying mutating tools.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/ToolDiscoveryTool.swift` — `tools.discover` implementation + `ToolBM25Index` struct
- `OraTests/ToolDiscoveryTests.swift` — unit tests for index, retrieval, and session cache

### 5.2 Files to Modify

- `Ora/Tools/ToolProtocol.swift` — add `var loadPolicy: ToolLoadPolicy { get }` with default `.deferred`; add `ToolLoadPolicy` enum
- `Ora/Tools/ToolRegistry.swift` — split `tools` dict into `coreTools`/`deferredTools`; add `bm25Index`; add `search(query:topK:)` and `addDiscovered(_:session:)`; update `registerDefaultTools` to call `buildIndex()`; update `schemas()` to accept policy filter
- `Ora/LLM/SystemPromptBuilder.swift` — update `build(...)` signature to accept `discoveredTools: [ToolDefinition]`; add `encodeCompactCatalog` formatter; update `{{tools}}` replacement to emit three sections
- `Ora/Tools/Calendar/CalendarQueryTool.swift` — add `var loadPolicy: ToolLoadPolicy { .core }`
- `Ora/Tools/Contacts/ContactsSearchTool.swift` — add `var loadPolicy: ToolLoadPolicy { .core }`
- `Ora/Tools/Reminders/RemindersListTool.swift` — add `var loadPolicy: ToolLoadPolicy { .core }`
- `Ora/Tools/Skills/SkillsListTool.swift` — add `var loadPolicy: ToolLoadPolicy { .core }`
- `Ora/Tools/System/SystemOpenAppTool.swift` — add `var loadPolicy: ToolLoadPolicy { .core }`
- `Ora/Tools/Skills/ToolRegistry.swift` — register `ToolDiscoveryTool` in `registerDefaultTools`
- `Ora/Orchestration/ConversationManager.swift` — clear discovered schema cache on `reset()`

### 5.3 Tests to Add

- `OraTests/ToolDiscoveryTests.swift`:
  - `test_bm25Index_buildsFromRegistry` — verify index contains all deferred tools
  - `test_bm25Index_ranksSendMessageHighest` — query "send a message" returns `messages.send` in top-3
  - `test_bm25Index_ranksCalendarCreateHighest` — query "create a meeting" returns `calendar.create_event` in top-3
  - `test_bm25Index_topKRespectsLimit` — topK=2 returns exactly 2 results
  - `test_bm25Index_emptyQueryReturnsEmpty` — empty/whitespace query returns `[]`
  - `test_toolDiscoveryTool_executesAndReturnsSchemas` — execute returns valid JSON with `tools` array
  - `test_sessionCache_persistsAcrossCalls` — second discover call in same session includes previously discovered tools
  - `test_sessionCache_clearsOnReset` — ConversationManager.reset() clears discovered set
  - `test_systemPromptBuilder_emitsThreeSections` — built prompt contains core block, catalog block, discovered block

### 5.4 Dependencies/Config

- No new Swift packages required
- No `project.yml` changes
- `ToolBM25Index` is self-contained in `ToolDiscoveryTool.swift`

## 6. Acceptance Criteria

- [ ] AC-1: `ToolLoadPolicy` enum exists with `.core` and `.deferred` cases; `Tool` protocol has `loadPolicy` with default `.deferred`
- [ ] AC-2: Exactly 5 tools are annotated `.core` (CalendarQuery, ContactsSearch, RemindersList, SkillsList, SystemOpenApp); all others default to `.deferred`
- [ ] AC-3: `ToolRegistry.buildIndex()` runs at startup and produces a BM25 index covering all deferred tools
- [ ] AC-4: `tools.discover` query "send a message" returns `messages.send` in the top-3 results
- [ ] AC-5: `tools.discover` query "search my files" returns `system.search_files` in the top-3 results
- [ ] AC-6: `tools.discover` with an empty query returns an error result (not a crash)
- [ ] AC-7: System prompt contains exactly three sections: core tool schemas, deferred compact catalog, discovered tool schemas
- [ ] AC-8: Compact catalog lines follow the format `tool_name[⚠]: one-line description` (⚠ only for mutating tools)
- [ ] AC-9: A tool schema discovered via `tools.discover` persists in the session cache and appears in the next turn's prompt discovered section
- [ ] AC-10: `ConversationManager.reset()` clears the discovered schema cache
- [ ] AC-11: Every `tools.discover` execution is audit-logged with query and matched tool names
- [ ] AC-12: Token count for core schemas + compact catalog is ≤40% of the previous all-schemas count (measured at 40 tools baseline)
- [ ] AC-13: All new tests pass; no existing tests regress

## 7. Verification Plan

### Automated Tests

- [ ] `OraTests/ToolDiscoveryTests.swift` — all 9 test cases above pass
- [ ] Existing `ToolRegistryTests` still pass (registry API backwards-compatible)
- [ ] `SystemPromptBuilderTests` updated to cover three-section format

### Manual Tests

- [ ] Launch app; open Overlay; say "open Spotify" — SystemOpenApp fires without discovery call (it's core)
- [ ] Say "send a message to Mom" — agent calls `tools.discover` with a relevant query, then calls `messages.send`
- [ ] Say "run my morning routine shortcut" — agent calls `tools.discover`, finds `system.run_shortcut`, executes it
- [ ] Say "search my files for budget" — agent calls `tools.discover`, finds `system.search_files`
- [ ] In a multi-turn session, ask about messages twice — second turn reuses cached schema without a second discover call
- [ ] Inspect logs: `./build.sh logs --category tools` — verify BM25 index build log and discovery query logs appear
- [ ] Run `./build.sh test` — all tests pass

## 8. Performance / Reliability Considerations

- **Index build time:** O(n) at n=40 tools; expected under 1ms. Logged via `os_signpost` if over 5ms.
- **Query time:** O(n×q) where q = query term count; expected under 1ms at n=40–100.
- **Token savings:** At 40 tools, estimated reduction from ~16K → ~5K tokens for the tool section (core schemas ~3K + compact catalog ~1.5K + zero discovered on first turn).
- **No ML dependencies:** Pure BM25, no embeddings, no CoreML — works without model warmup.
- **Graceful degradation:** If the index fails to build (malformed tool schema), `tools.discover` returns an error result; core tools are unaffected and the session continues normally.
- **Session cache growth:** Bounded by the number of deferred tools (~35 max); no memory concern.

## 9. Risks & Mitigations

- **BM25 retrieval misses for voice input** — ASR produces approximate text; BM25 is tolerant of single-word variations but can miss on entirely wrong words. Mitigation: keep tool descriptions rich with synonyms (e.g., "send" and "compose" in `messages.send` description); add `usage_examples` field to `ToolSchema` in a follow-up if needed.
- **Agent over-discovers** — the agent may call `tools.discover` on every turn even when core tools suffice. Mitigation: system prompt instructs to use core tools directly; monitor via audit log; tune prompt if frequency is too high.
- **Backwards compatibility** — existing tests that call `ToolRegistry.schemas()` expect all tools. Mitigation: add `schemas(policy: ToolLoadPolicy?)` overload; keep `schemas()` returning all tools for test compatibility.
- **Description quality** — 97.1% of tools in the wild have description quality issues; poor descriptions degrade BM25 accuracy. Mitigation: this story improves descriptions as part of adding `loadPolicy` annotations to each tool file (each tool file touched gets a description review pass).

## 10. Open Questions

- Should `tools.discover` return top-3 or top-5? Top-5 gives more recall; top-3 saves tokens. Default to 5; make it configurable via a constant.
- Should the compact catalog be sorted by domain (calendar, reminders, …) or by name? Domain grouping aids human readability of the prompt; name sort is simpler. Prefer domain grouping.
- Should `ToolDiscoveryTool` itself be a core tool? It should always be in context so the agent can always call it. Add it to core tools (it has a trivial schema — name + one parameter).

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
