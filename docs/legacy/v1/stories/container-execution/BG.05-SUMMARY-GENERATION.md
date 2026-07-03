# BG.05 - Summary Generation

**Epic:** Background Tasks
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** BG.02, BG.04
**Target:** macOS 26 (Tahoe)

## Summary

Generate `summary.md` from stored research artifacts using the **local** LLM runtime only. Summary jobs must stay off the foreground path, sanitize fetched content before inference, and cooperate with Ora’s existing MLX serialization rather than trying to manage the GPU lock themselves.

## Verification Notes

- Verified on 2026-03-16 against [SummaryGenerator.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/Summary/SummaryGenerator.swift), [SummaryPrompt.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/Summary/SummaryPrompt.swift), and `LLMService.generateOneShot`.
- Focused tests passed in `.artifacts/BGTests-2.xcresult`, including `SummaryGeneratorTests` and `SummaryContentSanitizerTests`.
- Follow-up fix on 2026-03-16 wires `SummaryGenerator` into [AppDelegate.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/AppDelegate.swift) and [BackgroundTaskManager.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/BackgroundTaskManager.swift), so completed tasks now enqueue and run summary generation in the default app path.

## Architecture Context and Reuse Guidance

- Use [LLMService.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/LLM/LLMService.swift) directly for summarization, not `LLMProviderManager`.
- Do **not** manually acquire [MLXMetalGate.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/LLM/MLXMetalGate.swift) before calling `LLMService`; `LLMService` already serializes GPU access.
- Foreground pipeline state transitions already live in [SimplePipelineController+State.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Orchestration/SimplePipelineController+State.swift).
- Keep summary state on `BackgroundTaskRecord`; do not invent a second persistence model for summary jobs.

## Resolved Decisions

- Summaries use `LLMService.shared` even when the user has a cloud provider selected.
- **Model selection (v1):** Use the currently loaded model via `LLMService.shared`. If no model is loaded, `prepare()` loads the default. No separate model configuration for background tasks in v1. A future story can add the option to use a smaller model (e.g., 3B) for lighter summaries.
- **KV cache isolation (CRITICAL):** Background summarization must **not** use or pollute the foreground conversation's persistent KV cache. Add a `generateOneShot(prompt:maxTokens:)` method to `LLMService` that creates a fresh context/cache for the call and discards it afterward. `SummaryGenerator` must use this method exclusively.
- Summary jobs run only when the foreground pipeline is inactive.
- If foreground work starts while a summary is generating, cancel and requeue the summary job.
- `summary.md` is markdown prose plus bullets; no structured JSON output file is added in this story.

## File Touch List

- `Ora/BackgroundTasks/Summary/SummaryGenerator.swift`
  Purpose: local-only summary job queue and execution.
- `Ora/BackgroundTasks/Summary/SummaryPrompt.swift`
  Purpose: deterministic summarization prompt builder.
- `Ora/BackgroundTasks/Summary/ContentSanitizer.swift`
  Purpose: strip unsafe/noisy content before inference.
- `Ora/BackgroundTasks/BackgroundTaskRecord.swift`
  Purpose: add `summaryState` and optional `summaryError`.
- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
  Purpose: enqueue summary jobs after artifacts are written.
- `Ora/Orchestration/SimplePipelineController+State.swift`
  Purpose: publish foreground activity notifications consumed by `SummaryGenerator`.
- `OraTests/BackgroundTasks/SummaryGeneratorTests.swift`
- `OraTests/BackgroundTasks/ContentSanitizerTests.swift`

## Implementation Steps

1. Add foreground activity notifications in `SimplePipelineController+State.swift`.
   Required signals:
   - foreground work started
   - foreground work became idle

   **Cross-isolation mechanism:** Use `NotificationCenter` (consistent with existing Ora patterns). `SimplePipelineController` is `@MainActor`; `SummaryGenerator` will be a non-`@MainActor` actor. Post `Notification.Name.oraForegroundWorkStarted` and `.oraForegroundWorkIdle` from the pipeline controller. `SummaryGenerator` observes via `NotificationCenter.default.notifications(named:)` async sequence.

2. Add summary state to `BackgroundTaskRecord`.
   States:
   - `pending`
   - `generating`
   - `complete`
   - `failed`

3. Implement `ContentSanitizer`.
   Rules:
   - remove remaining HTML tags
   - collapse whitespace
   - strip control characters
   - normalize Unicode (strip invisible characters, RTL overrides, zero-width joiners)
   - cap each page at `4_000` chars
   - cap combined input at `8_000` chars
   - **prompt injection framing:** wrap fetched content in clear delimiters before passing to the LLM: `[BEGIN FETCHED CONTENT FROM <url>]...[END FETCHED CONTENT]`. This does not prevent all prompt injection but makes the boundary explicit.
   - check model availability before attempting generation (if model download is incomplete, skip directly to extractive fallback)

4. Implement `SummaryGenerator`.
   Behavior:
   - observe foreground activity
   - queue pending summary jobs
   - start only when pipeline is idle
   - call `LLMService.shared.prepare()` and `generateOneShot(prompt:maxTokens:)` (NOT the multi-turn `generate` method)
   - collect the streamed output into one markdown string
   - on cancellation from foreground activity, requeue the job
   - **cancel/requeue bounds:** maximum 3 requeue attempts per task. After 3 cancellations, use extractive fallback. Minimum idle window of 5 seconds before starting a new summary attempt (prevents thrashing if user speaks frequently). Partially generated summaries are discarded on cancellation (not resumed).
   - on repeated failure (3 LLM failures or 3 requeue exhaustions), write an extractive fallback summary
   - **extractive fallback algorithm:** take the first 500 characters of extracted text from each page (up to 5 pages), concatenate with page URL headers, and write as `summary.md`. Format: `## <page title>\n<first 500 chars>\n\nSource: <url>\n\n---\n` per page. This is deliberately simple — it provides *something* useful rather than nothing.

5. Write `summary.md` into the artifact folder and update task summary state.

## Tests and Validation

- `test_sanitizer_stripsTagsAndControlCharacters`
- `test_sanitizer_capsPerPageAndTotalInput`
- `test_generator_usesLocalLLMServiceNotProviderManager`
- `test_generator_writesSummaryMarkdown`
- `test_generator_requeuesWhenForegroundWorkStarts`
- `test_generator_fallbackWritesExtractiveSummaryOnFailure`
- `test_generator_updatesSummaryState`
- `test_generator_maxRequeueAttemptsTriggersExtractiveFallback`
- `test_generator_respectsMinimumIdleWindow`
- `test_sanitizer_wrapsContentInDelimiters`
- `test_sanitizer_stripsUnicodeInvisibleCharacters`

Manual validation:
- Complete a task while Ora is idle and confirm `summary.md` is created.
- Start a new foreground turn while summarization is running and confirm the summary job is canceled/requeued.

## Acceptance Criteria

- [ ] Background-task summaries are generated through `LLMService.shared`, not a cloud provider.
- [ ] Summary generation does not manually acquire `MLXMetalGate`.
- [ ] Summary jobs only run while the foreground pipeline is idle and requeue on foreground interruption.
- [ ] Input content is sanitized and size-bounded before inference.
- [ ] `summary.md` is written for successful jobs, with an extractive fallback on repeated LLM failure.
- [ ] `BackgroundTaskRecord` tracks summary lifecycle state.

## File Touch List (additional)

- `Ora/LLM/LLMService.swift`
  Purpose: add `generateOneShot(prompt:maxTokens:)` method that creates a fresh KV cache context, generates, and discards the context. This prevents background summarization from corrupting the foreground conversation state.

## Risks and Open Questions

- Cancel/requeue behavior adds some coordination complexity, but it is necessary to protect Ora’s main interactive path.
- **KV cache isolation is the highest-risk item in this story.** If `generateOneShot()` is not implemented correctly, background summaries will corrupt foreground conversations. Test thoroughly with concurrent foreground + background generation.
- Prompt injection via fetched web content is a known risk surface. The content framing delimiters are a partial mitigation, not a complete defense.
