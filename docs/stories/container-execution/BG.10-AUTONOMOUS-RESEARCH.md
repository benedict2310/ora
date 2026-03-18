# BG.10 - Autonomous Research

**Epic:** Background Tasks
**Status:** 🚧 To Do
**Priority:** P1 (High)
**Estimated Effort:** 4 days
**Dependencies:** BG.09
**Target:** macOS 26 (Tahoe)

## Summary

Replace the URL-paste research UX with a single-approval autonomous model. The user says "research X" in natural language. Ora shows a brief confirmation ("I'll research that in the background"), the user approves once, and the container agent handles everything — source discovery, fetching, extraction — autonomously. No per-URL approval. No source-plan review. No autonomy mode selection.

The security model is the container (BG.09), not the approval dialog. Because the container can't touch the user's files, local network, or credentials, Ora doesn't need per-URL approval for autonomous topic research. One approval is enough.

## Why This Replaces BG.09/BG.10 (Old)

The old BG.09 (query-first planning) built an elaborate host-side planning layer with search providers, ranking algorithms, plan stores, and TTL caches — all to produce a "source plan" the user had to approve. The old BG.10 (autonomy modes) added safe/trusted/dangerous modes with policy persistence, session grants, and runtime capability modeling.

That complexity existed because the security boundary was on the host: every URL had to be validated, every action had to be gated. With container isolation (BG.09 new), the security boundary moves to the container runtime boundary. The container agent can do whatever research it needs. The host only needs to:

1. Accept a natural-language query from the user.
2. Confirm the user wants to start a research task.
3. Dispatch it to the container.
4. Receive structured results.

Everything that was in the old BG.09 planning layer now happens inside the container, where it's simpler (Python, not Swift) and safer (isolated, not host-side).

## Verification Notes

- The existing `research.start` tool in [ResearchStartTool.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/Research/ResearchStartTool.swift) accepts `urls: [String]` and `label: String?`. This story adds `query: String?` as an alternative input.
- The existing tool confirmation flow in [ToolProtocol.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/ToolProtocol.swift) and [ToolHost.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/ToolHost.swift) handles the single-approval UX. No new authorization mechanism is needed.
- `BackgroundTaskInputs` gains a `query` field in BG.09 (container runtime). This story uses it.
- The container agent (BG.09) already handles source discovery when `query` is present in `input.json`.
- The system prompt already injects tool schemas dynamically. This story only needs a small update to the hardcoded research guidance line in `system-prompt.txt`.

## Architecture Context and Reuse Guidance

- **Reuse** `ResearchStartTool` — extend it to accept `query` as an alternative to `urls`. Do not add a separate `research.plan` tool. The planning happens inside the container, invisible to the host.
- **Reuse** the existing `ToolKind.mutate` confirmation flow for the single approval. The confirmation prompt changes from a URL list to a topic description.
- **Reuse** `BackgroundTaskManager.enqueue()` — the only change is that `BackgroundTaskInputs` now carries a `query` instead of (or in addition to) `urls`.
- **Reuse** `ArtifactStore`, `SummaryGenerator`, `TaskNotificationService`, `TaskProgressObserver` — with the BG.09 schema updates for query/provenance.
- **Do not** add `ResearchPlanTool`, `ResearchPlanStore`, `ResearchPlanner`, `SearchProvider`, or any host-side planning infrastructure. The container agent owns discovery.
- **Do not** add `ResearchAutonomyMode`, `ResearchAuthorizationPolicy`, `WorkerRuntimeIsolation`, `WorkerRuntimeCapabilities`, or mode-dependent confirmation logic. There is one mode: containerized autonomous research.
- **Do not** add research mode settings to Preferences. There is nothing to configure.
- **Do not** add a `research.reveal` tool. Keep research tool outputs path-free and reuse existing Finder reveal behavior outside the research tool surface when needed.

## User Experience

### Query-Based Research (New)

```
User: "Research the latest Nvidia Blackwell server rollout"

Ora: "This will search the public web and fetch sources in an isolated container."

      [Start Research]  [Cancel]
```

One tap. Done. The container agent searches, discovers sources, fetches pages, extracts text, and writes structured results. Ora notifies the user on completion. The user can load results into the conversation later.

### URL-Based Research (Preserved)

```
User: "Summarize this article: https://example.com/nvidia-blackwell"

Ora: "This will fetch and summarize these URLs in an isolated container."

      [Start Research]  [Cancel]
```

Explicit URLs still work. The container agent fetches them directly without discovery. This preserves backward compatibility with BG.07.

### Progress Feedback

The existing task progress UI (BG.08) shows real-time status:

```
Menu bar: 🔍 Researching "Nvidia Blackwell rollout"
Overlay:  ⟳ Researching "Nvidia Blackwell rollout"    Cancel
```

### Result Loading

```
User: "What did you find about Nvidia Blackwell?"

Ora uses research.list_results → research.load_result to pull the summary
into the conversation, exactly as BG.07 already works.
```

## Resolved Decisions

- `research.start` accepts **either** `query` (string) **or** `urls` (array) **or both**. At least one must be provided. When both are present, the container agent uses the query for context and fetches the explicit URLs as mandatory sources.
- The confirmation prompt for query-based research shows the topic, not a URL list. Example: "Research: Nvidia Blackwell server rollout. This will search the public web and fetch sources in an isolated container."
- Per-session enqueue limit stays at `5` tasks (from BG.07). Cooldown stays at `30` seconds. These are simple abuse-prevention measures, not security boundaries.
- The system prompt tells Ora to use `research.start(query: ...)` for topic-based requests. No separate planning tool exists, and the prompt change should be limited to the existing hardcoded research guidance line.
- When the container runtime is unavailable (pre-macOS 26, container not installed), fall back to `URLSessionWorker` which requires explicit `urls`. Ora should tell the user: "I can research specific URLs for you, but topic-based research requires the container runtime."
- Explicit user-provided `urls` are still validated on the host before enqueue, even when the container backend is available.
- Research tool outputs should stop returning `artifact_path`; `task_id` is the stable handle.
- Progress uses the existing BG.08 state model. For query-based tasks, render `Researching` in the display layer while keeping the underlying state machine unchanged.

## File Touch List

- `Ora/Tools/Research/ResearchStartTool.swift`
  Purpose: accept `query` parameter, update confirmation prompt for topic-based research, update validation logic.

- `Ora/Resources/system-prompt.txt`
  Purpose: update the single hardcoded research guidance line so Ora prefers `research.start(query: ...)` for topic-based research instead of asking users to paste URLs.

- `Ora/Tools/Research/ResearchListResultsTool.swift`
  Purpose: include `query` and compact provenance metadata if available, without returning filesystem paths.

- `Ora/Tools/Research/ResearchLoadResultTool.swift`
  Purpose: include provenance (search queries used, domains, rationale) in loaded result if available from stored artifact data, without returning filesystem paths.

- `Ora/BackgroundTasks/Artifacts/ArtifactManifest.swift`
  Purpose: add compact query/provenance summary fields used by `research.list_results`.

- `Ora/BackgroundTasks/Artifacts/ArtifactStore.swift`
  Purpose: persist query/provenance in host-controlled artifact files and stop treating `artifact_path` as model-facing data.

- `OraTests/Tools/Research/ResearchToolsTests.swift`
  Purpose: add tests for query-based research flow.

## Implementation Steps

1. **Extend `ResearchStartTool` schema.**
   Add `query` parameter:
   ```swift
   var schema: ToolSchema {
       ToolSchema(
           name: name,
           description: "Start a background research task. Provide a topic query for autonomous research, or specific URLs to fetch and summarize.",
           parameters: [
               "query": ParameterSchema(type: "string", description: "Research topic in natural language"),
               "urls": ParameterSchema(type: "array", description: "Specific URLs to fetch (optional if query is provided)"),
               "label": ParameterSchema(type: "string", description: "Optional label for the research task")
           ],
           requiredParameters: [],  // At least one of query or urls is required
           requiresConfirmation: true
       )
   }
   ```

2. **Update `ResearchStartTool` validation.**
   - At least one of `query` or `urls` must be present.
   - If `query` is present: validate trimmed non-empty, max 500 chars.
   - If `urls` is present: existing URL validation (max count, max length, forbidden schemes).
   - If `urls` are present: keep host-side URL validation before enqueue, even when the container backend is available.
   - If both are present: both validations apply.

3. **Update confirmation prompt.**
   - Query-based: "Research: {query}. This will search the public web and fetch sources in an isolated container."
   - URL-based: existing prompt showing the URL list.
   - Mixed: "Research: {query}. This will search the public web, fetch sources in an isolated container, and include these specific URLs."

4. **Handle container unavailability.**
   - If `query` is provided but `ContainerWorker` is not available:
     - Return a tool error: "Topic-based research requires the container runtime, which is not available on this system. You can still research specific URLs."
   - If only `urls` are provided: works with either backend (container or in-process).

5. **Update `BackgroundTaskInputs`.**
   Already extended with `query: String?` in BG.09. Wire it through from the tool to the manager.

6. **Update prompt guidance.**
   Update the existing hardcoded research guidance line in the system prompt so it reflects query-based research:
   ```
   For research requests:
   - If the user asks to research a topic, use research.start with a query parameter.
   - If the user provides specific URLs, use research.start with a urls parameter.
   - Do not ask the user to provide URLs when they've given you a topic.
   - Research runs in an isolated container and still requires the normal single confirmation for research.start.
   ```

7. **Update `ResearchListResultsTool`.**
   Include `query` and compact provenance in the returned metadata so the user can see what was researched:
   ```json
   {
     "task_id": "...",
     "query": "Nvidia Blackwell server rollout",
     "label": "...",
     "state": "completed",
     "created_at": "...",
     "completed_at": "...",
     "domains_used": ["nvidia.com", "anandtech.com"]
   }
   ```
   Do not return `artifact_path`.

8. **Update `ResearchLoadResultTool`.**
   When loading a result, include provenance from the container output if available:
   ```json
   {
     "task_id": "...",
     "query": "Nvidia Blackwell server rollout",
     "summary": "...",
     "sources": [
       { "url": "...", "title": "...", "domain": "nvidia.com" }
     ],
      "search_queries_used": ["nvidia blackwell server", "blackwell GB200 rollout"],
     "discovery_rationale": "Selected sources covering official announcements and analysis."
   }
   ```
   This gives the user visibility into what the container agent did without requiring pre-approval of a source plan.

9. **Update `ArtifactStore` manifest.**
   Persist full provenance in `result.json` alongside page data. Persist compact rollups (for example `query` and `domains_used`) in `manifest.json` so `research.list_results` can stay lightweight.

## Tests and Validation

- `test_researchStart_acceptsQueryParameter`
- `test_researchStart_acceptsQueryAndURLsTogether`
- `test_researchStart_rejectsEmptyQueryAndNoURLs`
- `test_researchStart_rejectsTooLongQuery`
- `test_researchStart_confirmationPromptShowsTopicForQuery`
- `test_researchStart_confirmationPromptShowsURLsForURLs`
- `test_researchStart_confirmationPromptShowsBothForMixed`
- `test_researchStart_failsWithQueryWhenContainerUnavailable`
- `test_researchStart_worksWithURLsWhenContainerUnavailable`
- `test_researchStart_enqueuesTaskWithQueryInInputs`
- `test_researchStart_keepsHostValidationForExplicitURLs`
- `test_researchListResults_includesQueryInMetadata`
- `test_researchLoadResult_includesProvenanceFromContainer`
- `test_researchTools_doNotReturnArtifactPath`
- `test_researchStart_perSessionLimitStillEnforced`
- `test_researchStart_cooldownStillEnforced`
- `test_researchToolsRemainDeferred`

### Manual Validation

- Ask Ora: "Research the latest Nvidia Blackwell server rollout."
  - Confirm Ora shows a single-approval confirmation with the topic.
  - Confirm the task runs in a container (check logs).
  - Confirm a notification arrives on completion.
  - Confirm `research.load_result` returns a summary with provenance.

- Ask Ora: "Summarize https://example.com/article"
  - Confirm existing URL-based flow still works.

- Ask Ora a follow-up: "What did you find?"
  - Confirm Ora uses `research.list_results` → `research.load_result` to surface the result.

- On a system without container runtime:
  - Ask Ora to research a topic → confirm Ora explains container is needed.
  - Ask Ora to summarize a URL → confirm it still works via in-process worker.

## Acceptance Criteria

- [ ] Users can ask for topic-based research in natural language without providing URLs.
- [ ] `research.start` accepts a `query` parameter and dispatches to the container agent.
- [ ] The confirmation dialog shows the research topic, not a URL list, for query-based research.
- [ ] One approval starts the entire research task — no per-URL or per-source approval.
- [ ] Explicit URL-based research (`research.start(urls: [...])`) continues to work.
- [ ] Explicit user-provided `urls` are still validated on the host before enqueue.
- [ ] Results include provenance data (search queries used, domains, rationale) from the container.
- [ ] System prompt guides Ora to use `query`-based research for topic requests.
- [ ] Falls back gracefully when container runtime is unavailable.
- [ ] Per-session enqueue limits and cooldown are preserved.
- [ ] Research tool outputs no longer expose `artifact_path` to the model.
- [ ] No new tools, no planning layer, no autonomy modes, no mode selection UI.

## Risks and Open Questions

- **Quality depends on the container agent.** If the in-container research agent produces poor results (bad search queries, irrelevant sources, weak extraction), the UX suffers regardless of how clean the Swift integration is. The agent script needs its own testing and iteration cycle, separate from the Swift codebase.
- **Fallback UX on pre-macOS 26 systems.** Users without container support get the old URL-paste experience. This is acceptable for v1 but should be communicated clearly in Ora's marketing and onboarding.
- **No user control over search strategy.** The user can't specify "only use academic sources" or "focus on news articles" in v1. The container agent uses its own heuristics. This is a feature request for a future story (research constraints / preferences).
- **Provenance visibility.** The user sees provenance after the fact (when loading results), not before. This is intentional — pre-approval of a source plan adds friction without adding safety when the container is isolated. But some users may want to know what Ora plans to do before it does it. A future story could add an optional "show me the plan first" mode for power users, without making it the default.
- **Model-facing path hygiene.** Removing `artifact_path` from research tool outputs is intentional. If a user wants Finder reveal behavior later, route that through existing system/Finder surfaces rather than path-bearing research payloads.
