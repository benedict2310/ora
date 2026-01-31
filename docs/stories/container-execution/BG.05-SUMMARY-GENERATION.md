# BG.05 - Summary Generation

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** BG.02, BG.04
**Target:** macOS 26 (Tahoe)
**Design Reference:** BG.00

---

## 1. Objective

Generate a concise, human-readable `summary.md` from background task results using the local LLM. The summary must be safe (no raw HTML injected into context), queued properly behind active conversation turns (GPU serialization), and written to the artifact folder alongside `result.json`.

## 2. User Story

As a **user**, I want background research results to include a **readable summary** so that I can **quickly understand the findings without reading raw extracted text**.

## 3. Scope

### In Scope

- `SummaryGenerator` actor that loads `result.json` and produces `summary.md`
- Content sanitization before LLM injection (strip HTML, limit input length, escape control characters)
- GPU serialization: queue summary generation behind active conversation via `MLXMetalGate`
- Dedicated summarization prompt (not the conversation system prompt)
- Fallback: if LLM is busy or fails after retries, write a basic extractive summary (first N sentences)
- Write `summary.md` to the task's artifact folder
- Update task record with summary status

### Out of Scope

- Real-time streaming of summary generation to UI
- Multi-document synthesis (each page summarized independently, then combined)
- Embedding-based retrieval or semantic search
- Custom summary templates or user-configurable summary length

## 4. Architecture Alignment

### Component Placement

```
Ora/BackgroundTasks/
  ├── Summary/
  │   ├── SummaryGenerator.swift        // Actor: orchestrates summarization
  │   ├── SummaryPrompt.swift           // Prompt template for summarization
  │   └── ContentSanitizer.swift        // Strip HTML, limit length, escape
  └── ... (existing from BG.01, BG.02, BG.04)
```

### GPU Serialization (Critical)

MLX uses a single Metal command queue. The LLM and TTS cannot generate concurrently. Ora already handles this via `MLXMetalGate` in `Ora/LLM/MLXMetalGate.swift`.

```
Active Conversation Turn (LLM + TTS)
  |
  └── completes → MLXMetalGate releases
                    |
                    v
              SummaryGenerator acquires MLXMetalGate
                    |
                    ├── Generates summary via LLMService
                    ├── Writes summary.md
                    └── Releases MLXMetalGate
```

**Rules:**
- Summary generation NEVER preempts an active conversation turn
- If user starts a new conversation while summary is generating, cancel summary and re-queue
- Summary generation uses a lower priority than conversation (yield on contention)

### Sanitization Pipeline

```
result.json (WorkerResult)
  |
  ├── For each page:
  |   ├── Strip any residual HTML tags
  |   ├── Normalize whitespace (collapse runs, trim)
  |   ├── Escape control characters
  |   ├── Truncate to 4000 chars per page
  |   └── Combine into sanitized input
  |
  ├── Total input capped at 8000 chars (across all pages)
  |
  └── Wrapped in summarization prompt → LLM
```

### Summarization Prompt

```
You are summarizing research results. Produce a concise markdown summary.

RULES:
1. Write 3-5 bullet points covering the key findings.
2. Include a one-sentence overview at the top.
3. Cite sources using [Source Title](URL) format.
4. Do not include raw URLs or HTML.
5. Keep the summary under 500 words.

RESEARCH DATA:
---
{sanitized_content}
---

SOURCES:
{citations_list}

Write the summary now:
```

### Integration Points

| Component | Integration |
|:----------|:------------|
| `MLXMetalGate` | Acquire before LLM generation, release after |
| `LLMService` | Use existing `generate()` method with summarization messages |
| `ArtifactStore` | Read `result.json`, write `summary.md` |
| `BackgroundTaskManager` | Trigger summary after worker completion |
| `TaskNotificationService` (BG.06) | Include summary preview in completion notification |

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/Summary/SummaryGenerator.swift` — Actor: load result, sanitize, generate summary, write file
- `Ora/BackgroundTasks/Summary/SummaryPrompt.swift` — Prompt template with content injection
- `Ora/BackgroundTasks/Summary/ContentSanitizer.swift` — HTML stripping, length limiting, escaping
- `OraTests/BackgroundTasks/SummaryGeneratorTests.swift` — Unit tests
- `OraTests/BackgroundTasks/ContentSanitizerTests.swift` — Sanitization tests

### 5.2 Files to Modify

- `Ora/BackgroundTasks/BackgroundTaskManager.swift` — Trigger `SummaryGenerator` after worker completes and artifacts are saved
- `Ora/BackgroundTasks/BackgroundTask.swift` — Add `summaryStatus` field (pending, generating, complete, failed)

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/ContentSanitizerTests.swift`:
  - `test_sanitize_stripsHTMLTags`
  - `test_sanitize_normalizesWhitespace`
  - `test_sanitize_escapesControlCharacters`
  - `test_sanitize_truncatesLongContent`
  - `test_sanitize_combinesMultiplePages`
  - `test_sanitize_capsTotalAt8000Chars`
  - `test_sanitize_handlesEmptyInput`
  - `test_sanitize_handlesUnicodeContent`
- `OraTests/BackgroundTasks/SummaryGeneratorTests.swift`:
  - `test_generate_producesMarkdownSummary` (mock LLM)
  - `test_generate_writesSummaryToArtifactFolder`
  - `test_generate_fallbackOnLLMFailure`
  - `test_generate_respectsMLXMetalGate`
  - `test_generate_cancellableOnNewConversation`

### 5.4 Dependencies/Config

- None (reuses existing `LLMService`, `MLXMetalGate`)

## 6. Acceptance Criteria

- [ ] AC-1: `SummaryGenerator` reads `result.json` from artifact folder and produces `summary.md`
- [ ] AC-2: Content is sanitized before LLM injection (no HTML tags, max 8000 chars total, control chars escaped)
- [ ] AC-3: Summary generation acquires `MLXMetalGate` and never preempts active conversation
- [ ] AC-4: If LLM fails after 2 retries, a basic extractive fallback summary is written (first 3 sentences per page)
- [ ] AC-5: `summary.md` is valid Markdown with bullet points and source citations
- [ ] AC-6: Summary generation is cancelable (responds to task cancellation within 2s)
- [ ] AC-7: Task record updated with `summaryStatus` (pending, generating, complete, failed)
- [ ] AC-8: Per-page input truncated to 4000 chars; total input capped at 8000 chars
- [ ] AC-9: `GPU.clearCache()` called after summary generation completes

## 7. Verification Plan

### Automated Tests

- [ ] Content sanitization unit tests (HTML stripping, truncation, escaping)
- [ ] Summary generation with mocked LLM (verify prompt structure, output parsing)
- [ ] Fallback path test (LLM returns error, extractive summary written)
- [ ] File write verification (summary.md exists and is valid Markdown)

### Manual Tests

- [ ] Trigger a background research task end-to-end and verify `summary.md` appears in artifact folder
- [ ] Start a conversation while summary is generating — verify conversation is not delayed
- [ ] Force LLM failure and verify fallback summary is readable
- [ ] Check GPU memory after summary generation (should not grow unbounded)

## 8. Performance / Reliability Considerations

- Summary generation adds 2-5 seconds per task (LLM inference on ~8000 char input)
- GPU memory: reuses existing LLM model; no additional model loading
- `GPU.clearCache()` called after summary generation (consistent with existing pattern in `LLMService`)
- If summary queue grows (multiple tasks complete while user is in conversation), process sequentially
- Summary LLM generation uses `maxTokens: 600` (sufficient for 500-word summary)

## 9. Risks & Mitigations

- **Prompt injection via extracted content** — Sanitization pipeline strips HTML and limits length; summarization prompt uses a separate system message (not the conversation system prompt) with explicit "data only" framing
- **GPU contention with conversation** — `MLXMetalGate` serializes access; summary yields to conversation. Worst case: summary is delayed, not conversation
- **LLM generates unsafe summary** — Summary is shown to user (not fed back to agentic loop); low risk. Future: add output validation
- **Large result sets** — Truncation to 8000 chars means some content is lost; acceptable for v1. Future: chunked summarization with multi-pass combining

## 10. Open Questions

- Should the summarization use the same model as conversation (Qwen 3) or a dedicated smaller model? (Proposed: same model — avoids loading a second model into GPU memory)
- Should summaries be re-generatable if the user doesn't like them? (Proposed: not in v1)
- Should the summary include structured data (key-value pairs) in addition to prose? (Proposed: prose only for v1)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
