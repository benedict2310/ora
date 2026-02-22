# S.00 - Context Budget

**Epic:** Skills
**Status:** Not Started
**Priority:** P0 (Critical Path) — prerequisite for S.01 and all subsequent Skills stories
**Estimated Effort:** 1 day
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

The conversation context budget (`maxContextTokens = 6,000`) is set to 2.3% of the model's actual capacity (Qwen 3 4B supports 262,144 tokens). As of today, the system prompt alone consumes ~4,150 tokens (69% of the budget), leaving only ~1,850 tokens for conversation history. FIFO trimming kicks in after roughly 3–5 exchanges. Adding Skills (S.01 + S.05) will push the system prompt to ~4,800 tokens, shrinking available history to ~1,200 tokens — unusable for multi-step workflows.

This story raises the context budget to a level appropriate for the model and compacts the `{{tools}}` registry format, recovering ~1,155 tokens. Together these two changes give Skills — and future tool additions — the headroom they need without any model-side changes.

### Current token budget breakdown (37 tools, pre-Skills)

| Component | Chars | ~Tokens |
|:----------|------:|-------:|
| Narrative + behavioral rules | 7,184 | 2,155 |
| `{{tools}}` registry block | 6,643 | 1,993 |
| **Total system prompt** | **13,827** | **~4,150** |
| Remaining for conversation | — | **~1,850** |

### After this story (same 37 tools)

| Component | ~Tokens |
|:----------|-------:|
| Narrative + behavioral rules | 2,155 |
| `{{tools}}` compact block | ~835 |
| **Total system prompt** | **~2,990** |
| `maxContextTokens` | 32,000 |
| Remaining for conversation | **~29,010** |

## 2. User Story

As a user, I want Ora to remember the full context of a long conversation without silently forgetting earlier turns, so that multi-step tasks (scheduling, drafting emails, managing multiple reminders) work reliably from start to finish.

## 3. Scope

### In Scope

- Raise `maxContextTokens` from 6,000 to 32,000 in `ConversationManager`
- Extract the constant with a named symbol and a comment referencing the model's actual capacity
- Rewrite `SystemPromptBuilder.encodeToolSchemas()` with a compact one-line-per-tool format
- Update all tests that reference the old constant or the old verbose tool encoding format

### Out of Scope

- Changes to the system prompt narrative text (behavior rules, domain guidance)
- Changes to `ToolSchema` or `ParameterSchema` structs
- Dynamic / per-request tool filtering
- Raising the GPU KV-cache limit (already set to 512MB in `LLMService.swift`)
- Any skills-specific system prompt additions (those live in S.01)

## 4. Architecture Alignment

- **`ConversationManager`** is a Swift `actor` (`Ora/LLM/ConversationManager.swift`). The `maxContextTokens` constant is a private `let` on the `init` parameter. Change the default value; no interface change needed.
- **`SystemPromptBuilder`** is a pure struct with a static `encodeToolSchemas` method. No actor or MainActor constraints — safe to change in isolation.
- **Compact format design** — one line per tool, no wrapping:
  ```
  {name}[confirm]?: {short description} [{param:type*, param:type, ...}]
  ```
  - `[confirm]` appended for mutating tools (LLM uses this to decide `proposal` vs `tool_call`)
  - `*` marks required parameters; no `*` means optional
  - Type abbreviations: `str`, `int`, `bool`, `datetime`, `str[]`
  - Tools with no parameters: omit the bracket block entirely
  - Line separator: `\n` (no blank lines between tools)

  **Example — current format (~245 chars for this tool):**
  ```
  - mail.send (Requires confirmation): Send an email via Apple Mail. Requires confirmation.
    Parameters: to: string: Comma-separated recipient email addresses, subject: string: Email subject line, body: string: Email body text, cc: string: Comma-separated CC email addresses (optional), bcc: string: Comma-separated BCC email addresses (optional), account: string: Mail account name to send from (optional)
  ```

  **Example — compact format (~85 chars):**
  ```
  mail.send[confirm]: send email via Mail [to:str*, subject:str*, body:str*, cc:str, bcc:str, account:str]
  ```

- **Why descriptions are safe to drop:** The system prompt narrative sections (rules 8–13) already provide full behavioral guidance for every tool domain (when to call which tool, what to do if a parameter is missing, edge cases). The compact format only needs to tell the model which parameters are required and what types to use for correct JSON output.
- **Context trimming** — `ConversationManager.trimContextIfNeeded()` uses the `maxContextTokens` constant directly. The FIFO strategy is unchanged; it simply kicks in much later. The memory impact is bounded by MLX's GPU cache limit (`GPU.set(cacheLimit:)` in `LLMService.swift`).
- **No audit logging** — this is a prompt-building change, not a tool execution change.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

None.

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/LLM/ConversationManager.swift` | Change `maxContextTokens` default from `6000` to `32000`; add inline comment citing model capacity |
| `Ora/LLM/SystemPromptBuilder.swift` | Rewrite `encodeToolSchemas(_:)` to emit compact one-line-per-tool format per §4 spec |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/LLM/ConversationManagerTests.swift` | Update any test that constructs `makeTestInstance(maxContextTokens: 6000)` with explicit value — those tests are fine; update any test asserting the *default* constant value |
| `OraTests/LLM/SystemPromptBuilderTests.swift` | Update golden-output tests to expect compact format; add snapshot test asserting all 37 tool names appear in encoded output; add test that `[confirm]` appears for every mutating tool and not for read-only tools; add test that `*` marks required params |

### 5.4 Dependencies/Config

- No new Swift packages or project.yml changes

## 6. Acceptance Criteria

### Context Budget

- [ ] AC-1: `ConversationManager`'s default `maxContextTokens` is 32,000
- [ ] AC-2: The constant is documented with a comment: `// Qwen 3 4B supports 262K tokens; 32K is a conservative cap that leaves ~29K for conversation after the system prompt`
- [ ] AC-3: At a fresh session start, `estimateTotalTokens()` returns a value well under 32,000 (i.e., system prompt only)
- [ ] AC-4: Conversation history is NOT trimmed during a 20-turn session with typical message lengths (~200 chars each)

### Compact Tool Format

- [ ] AC-5: `encodeToolSchemas(_:)` outputs one line per tool, no trailing blank lines
- [ ] AC-6: Mutating tools (`kind == .mutate`) have `[confirm]` appended to the name
- [ ] AC-7: Required parameters are marked with `*` suffix on the type; optional parameters have no suffix
- [ ] AC-8: Type abbreviations used: `str` (string), `int` (number/integer), `bool` (boolean), `datetime` (ISO 8601 date-time string), `str[]` (array of strings)
- [ ] AC-9: All 37 currently registered tool names appear in the encoded output
- [ ] AC-10: Total char count of the encoded output for all 37 tools is ≤ 3,500 chars (down from 6,643)
- [ ] AC-11: `SystemPromptBuilder.build(tools:)` still compiles and produces a valid, non-empty string with all tools present

### Regression

- [ ] AC-12: All existing `ConversationManagerTests` pass (no behavioral change, only budget increase)
- [ ] AC-13: All existing `SystemPromptBuilderTests` pass after updating golden expectations
- [ ] AC-14: Full test suite passes (`./build.sh test`)

## 7. Verification Plan

### Automated Tests

- [ ] `ConversationManagerTests` — verify default budget is 32,000; verify no trimming after 20 turns of ~200-char messages
- [ ] `SystemPromptBuilderTests` — snapshot test: encode all 37 real tool schemas, assert output ≤ 3,500 chars; assert all tool names present; assert `[confirm]` on all mutating tools; assert `*` on all required params
- [ ] Full suite: `./build.sh test`

### Manual Tests

- [ ] Build and launch app; start a long conversation (10+ turns with tool calls); verify earlier turns are still visible in the overlay transcript and not silently trimmed
- [ ] Inspect system prompt in logs (`./build.sh logs --category llm`) — verify compact tool listing is readable and correctly formatted
- [ ] Verify the model still calls tools correctly with the compact format: ask "what's on my calendar today?", "remind me to call Sarah tomorrow", "send an email to..." — confirm tool calls arrive with correct parameter names

## 8. Performance / Reliability Considerations

| Concern | Notes |
|:--------|:------|
| KV cache memory | Growing from 6K → 32K context window doesn't change peak memory unless conversations actually fill the window. GPU cache limit (512MB, set in `LLMService.swift`) caps this. |
| Inference latency | Proportional to actual tokens processed per turn, not the budget ceiling. Short conversations stay fast. |
| Compact format LLM accuracy | Risk that removing parameter descriptions hurts JSON quality. Mitigated by: (a) narrative sections already explain each tool, (b) parameter names are self-documenting, (c) manual smoke tests required before merging. |
| FIFO trim edge case | `minMessages = 1` guard in `trimContextIfNeeded()` is unchanged — oversized single messages still log a warning but don't crash. |

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Compact format confuses model, tools called with wrong params | Manual smoke test all tool categories before merging; if any regression is found, add description back for that specific tool's parameters |
| Future developers don't understand why the budget is 32K | The named constant comment explains it; update if the model changes |
| maxContextTokens = 32K still insufficient for very long sessions | FIFO trim still applies; at 32K and ~150 tokens/exchange, ~200 turns fit before trimming — sufficient for any realistic session |

## 10. Open Questions

- Should `maxContextTokens` be user-configurable (e.g., a Preferences slider for "conversation memory length")? **Defer** — 32K covers all practical cases; revisit only if power users request it.
- Should the compact format include a "tools:" header line to make the section scannable? **Implement as you see fit** — the `AVAILABLE TOOLS:` header line already in the system prompt template serves this purpose.

---

## Implementation Summary

**Date:** 2026-02-22
**Branch:** `feat/S.00-context-budget`
**Commits:** 2
**Implemented by:** codex (complexity score: 7/10)
**Reviewed by:** codex (1 iteration — pi unavailable, ToS violation)

### Files Changed
- `Ora/LLM/ConversationManager.swift` — raised `maxContextTokens` default to 32,000 with model-capacity comment
- `Ora/LLM/SystemPromptBuilder.swift` — rewrote `encodeToolSchemas(_:)` to emit compact one-line-per-tool format
- `Ora/Orchestration/AgentLoop.swift` — minor alignment update
- `OraTests/LLM/ConversationManagerTests.swift` — added tests for 32K budget and 20-turn no-trim scenario
- `OraTests/LLM/SystemPromptBuilderTests.swift` — updated golden expectations; added snapshot, `[confirm]`, `*` marker, and char-count tests

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-22T17:11:10Z
**Commit reviewed:** df1fb9d
**Iteration:** 1

### Summary
- Files reviewed: 5
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- None.

#### P1 - Major (Should fix)
- None.

#### P2 - Minor (Can defer)
- None.

### Future Considerations (Out of Scope)
- None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
