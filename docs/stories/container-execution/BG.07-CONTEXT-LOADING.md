# BG.07 - Context Loading

**Epic:** Background Tasks
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** BG.01, BG.04, BG.05
**Target:** macOS 26 (Tahoe)

## Summary

Add research tools that let Ora list saved results, load a compact summary into the conversation, and enqueue new URL-based background tasks. The tools must fit the current agent loop and prompt architecture: compact JSON results, normal `Tool` protocol conformance, and registration through `ToolRegistry` without hand-editing the system prompt template.

## Verification Notes

- Verified on 2026-03-16 against [ResearchStartTool.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/Research/ResearchStartTool.swift), [ResearchListResultsTool.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/Research/ResearchListResultsTool.swift), [ResearchLoadResultTool.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/Research/ResearchLoadResultTool.swift), and [ToolRegistry.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/ToolRegistry.swift#L202).
- Focused tests passed in `.artifacts/BGTests-2.xcresult`, including `ResearchToolsTests`.
- Current implementation detail: `research.list_results` lists saved artifact manifests only; it does not return queue `state` or `summary_state`.
- Re-verified on 2026-03-16 after the BG.04/BG.05 integration fixes. `research.start` now runs on a path that persists artifacts and background summaries for later `research.load_result` calls.

## Architecture Context and Reuse Guidance

- Tool protocol and authorization behavior live in [ToolProtocol.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/ToolProtocol.swift).
- Tool registration lives in [ToolRegistry.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/ToolRegistry.swift).
- The prompt already injects tool schemas dynamically through [system-prompt.txt](/Users/bene/Dev-Source-NoBackup/ora/Ora/Resources/system-prompt.txt) and [SystemPromptBuilder.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/LLM/SystemPromptBuilder.swift); do **not** add hard-coded research prose to the template.
- `AgentLoop` currently inserts full tool JSON into conversation context. Keep research-tool outputs compact enough to avoid bloating context.
- Current conversation budget is `32_000` tokens in [ConversationManager.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/LLM/ConversationManager.swift#L25), but the returned research payload should still stay intentionally small.

## Resolved Decisions

- `research.start` requires explicit `urls`; `query`/`label` is optional display text only.
- All three research tools are registered as `.deferred` tools so they appear through tool discovery instead of inflating the always-on prompt.
- No system-prompt file edits are required beyond normal schema injection.
- `research.start` is classified as a **`write` tool requiring confirmation** in v1. Although enqueueing feels lightweight, it triggers outbound network requests to user-specified URLs. A prompt injection in previously fetched content could instruct the LLM to enqueue additional URLs, enabling data exfiltration via URL parameters. The confirmation gate prevents autonomous chaining.
- Per-session enqueue limit: **5 tasks per session**. Cooldown: **30 seconds** between enqueue calls.

## File Touch List

- `Ora/Tools/Research/ResearchStartTool.swift`
  Purpose: validate URLs and enqueue a background task.
- `Ora/Tools/Research/ResearchListResultsTool.swift`
  Purpose: list saved task/artifact metadata.
- `Ora/Tools/Research/ResearchLoadResultTool.swift`
  Purpose: load a compact, bounded summary payload into the agent loop.
- `Ora/Tools/ToolRegistry.swift`
  Purpose: register the research tools.
- `OraTests/Tools/Research/ResearchToolsTests.swift`
  Purpose: registration/validation/payload-bounds coverage.

## Implementation Steps

1. Implement `ResearchStartTool`.
   Parameters:
   - `urls: [string]` required
   - `label: string` optional

   **Input validation at tool level (defense in depth, before BG.03 safety layer):**
   - Maximum URL count per call: `10` (matching `maxRequests`)
   - Maximum URL string length: `2048` characters
   - Reject `data:`, `javascript:`, `file:` schemes immediately
   - Normalize URLs before passing to the safety layer (handle percent-encoding, punycode)
   - Enforce per-session enqueue limit and cooldown

   Return payload:
   - `task_id`
   - `state`
   - `label`
   - `message` (should include "I'll notify you when it's ready" for natural LLM relay)

2. Implement `ResearchListResultsTool`.
   Return lightweight metadata only:
   - `task_id`
   - `label`
   - `created_at`
   - `completed_at`
   - `state`
   - `summary_state`
   - `artifact_path`

3. Implement `ResearchLoadResultTool`.
   Read from `summary.md` first, then fall back to a compact extractive summary from `result.json`.

   Return payload must stay compact:
   - `task_id`
   - `label`
   - `completed_at`
   - `summary` capped to a few thousand characters
   - `citations` capped to a small list
   - `artifact_path`

4. Register all three tools in `ToolRegistry.registerDefaultTools()`.
   Note: `.deferred` is already the default `loadPolicy` (see `ToolProtocol.swift`), so no explicit override is needed. Research tools use the default policy.

5. **Validation boundary clarification:** `ResearchStartTool` validates input plausibility (URL count, length, obvious bad schemes). `SafeURLSession` (BG.03) validates network safety (SSRF, IP ranges, content types). Both layers are required — this is defense in depth.

## Tests and Validation

- `test_researchStart_validateRequiresURLs`
- `test_researchStart_enqueuesTask`
- `test_researchListResults_returnsNewestFirst`
- `test_researchLoadResult_prefersSummaryMarkdown`
- `test_researchLoadResult_fallsBackToResultJSON`
- `test_researchLoadResult_boundsReturnedPayloadSize`
- `test_researchTools_areDeferred`
- `test_researchStart_rejectsOversizedURLs`
- `test_researchStart_rejectsTooManyURLs`
- `test_researchStart_rejectsDataAndJavascriptSchemes`
- `test_researchStart_enforcesPerSessionLimit`
- `test_researchStart_enforcesCooldown`
- `test_researchStart_requiresConfirmation`

Manual validation:
- Ask Ora to summarize explicit URLs in the background.
- Later ask what research results exist and load one.
- Ask a follow-up question after loading and confirm the agent uses the loaded summary.

## Acceptance Criteria

- [ ] `research.start` enqueues a URL-based task and returns task metadata.
- [ ] `research.list_results` returns lightweight saved-result metadata only.
- [ ] `research.load_result` returns a compact summary payload suitable for `AgentLoop` context injection.
- [ ] Research tools are registered through `ToolRegistry` and use `.deferred` load policy.
- [ ] No manual edit to `system-prompt.txt` is required for tool availability.
- [ ] Missing or deleted artifacts return descriptive tool errors instead of crashing.
- [ ] `research.start` requires user confirmation before enqueueing.
- [ ] Input validation at the tool level rejects oversized URLs, excessive URL counts, and unsafe schemes.
- [ ] Per-session enqueue limit and cooldown are enforced.

## Risks and Open Questions

- Because v1 does not include source discovery, generic “research this topic” requests still need either explicit URLs or a future search/discovery story.
