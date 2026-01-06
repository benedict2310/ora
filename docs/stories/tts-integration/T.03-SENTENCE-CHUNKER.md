# T.03 - Sentence Chunker

**Epic:** TTS Integration
**Status:** ✅ Complete
**Priority:** P2 (Nice to Have)
**Estimated Effort:** 0.5 days
**Dependencies:** T.01, T.02, O.03
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Split streaming LLM text into sentences for early TTS start, enabling voice output before the full response is generated. Also prevent Kokoro failures on long text by keeping each chunk under Kokoro's token limits.

---

## 2. User Story

As a user, I want Ora to start speaking responses quickly and clearly, even for longer answers, so I don’t have to wait for the entire response to finish or hear fallback voices.

---

## 3. Scope

### In Scope
- Chunk streaming text into sentence-sized pieces.
- Enforce safe chunk sizes to avoid Kokoro token overflow.
- Queue chunks for playback in order.
- Keep overall response text visible in the UI as it streams.

### Out of Scope
- Full prosody control or voice style selection.
- Parallel TTS for multiple responses.
- Alternate TTS engines beyond Kokoro + AVSpeech fallback.

### Current State (Post O.03)
- LLM streams tokens into `currentResponse` in `SimplePipelineController`.
- TTS starts only after the full response completes.
- `KokoroEngine.synthesize(...)` receives the full response as one batch and yields a single audio chunk.

### Newly Observed Limitation (2026-01-06)
KokoroSwift enforces a hard input token limit:
- `KokoroTTS.Constants.maxTokenCount = 510`
- Throws `KokoroTTSError.tooManyTokens` when exceeded

Long responses can exceed this limit, causing Kokoro to fail and fall back to AVSpeechSynthesizer.

---

## 4. Architecture Alignment

- **Pipeline:** `SimplePipelineController` streams LLM output and should emit sentence chunks for TTS as they complete.
- **TTS:** `TTSService` routes to `KokoroEngine` when available; fallback is AVSpeechSynthesizer.
- **Chunking:** New `SentenceChunker` lives in `Ora/TTS/SentenceChunker.swift` and enforces a safe chunk size.
- **Limit awareness:** Chunking must keep text under Kokoro’s 510-token limit (use conservative character caps if tokenization is not available at this layer).

---

## 5. Implementation Plan

### 5.1 Files to Create
- `Ora/TTS/SentenceChunker.swift` - streaming sentence chunker with size caps.
- `Ora/LLM/ResponseTextStreamParser.swift` - extract response text while JSON streams.
- `OraTests/SentenceChunkerTests.swift` - sentence boundaries and size limit coverage.

### 5.2 Files to Modify
- `Ora/Orchestration/SimplePipelineController.swift` - stream response tokens into chunker, enqueue TTS.
- `Ora/Orchestration/AgentLoop.swift` - forward response tokens to delegate.
- `Ora/LLM/StructuredGenerator.swift` - optional token handler while generating.
- `Ora/TTS/TTSService.swift` - synthesize per sentence chunk; add streaming entrypoint.
- `Ora/TTS/KokoroEngine.swift` - protocol extraction for testability.
- `OraTests/TTSServiceTests.swift` - long input split coverage.

### 5.3 Tests to Add
- `OraTests/SentenceChunkerTests.swift`
- `OraTests/TTSServiceTests.swift` (long input splitting and chunk size cap)

---

## 6. Acceptance Criteria

- [x] **AC-1:** Sentences extracted as they complete. ✅ Verified in `Ora/TTS/SentenceChunker.swift`.
- [x] **AC-2:** Remaining text flushed at end. ✅ Verified in `Ora/TTS/SentenceChunker.swift`.
- [x] **AC-3:** Handles streaming token input. ✅ Verified in `Ora/TTS/SentenceChunker.swift` and `Ora/Orchestration/SimplePipelineController.swift`.
- [x] **AC-4:** Uses NaturalLanguage for proper sentence detection. ✅ Verified in `Ora/TTS/SentenceChunker.swift`.
- [x] **AC-5:** Minimum sentence length filter to avoid tiny fragments. ✅ Verified in `Ora/TTS/SentenceChunker.swift`.
- [x] **AC-6:** Chunks stay under Kokoro token limit (no `KokoroTTSError.tooManyTokens`). ✅ Verified by `OraTests/SentenceChunkerTests.swift` and `OraTests/TTSServiceTests.swift`.
- [x] **AC-7:** Integration with `SimplePipelineController` (speak sentence chunks during LLM streaming). ✅ Verified in `Ora/Orchestration/SimplePipelineController.swift`, `Ora/Orchestration/AgentLoop.swift`, and `Ora/LLM/StructuredGenerator.swift`.

---

## 7. Verification Plan

### Automated Tests
- `SentenceChunkerTests` for sentence boundaries and chunk size caps.
- `TTSServiceTests` for long input splitting and Kokoro error avoidance.

### Manual Tests
- Stream a long LLM response (3+ paragraphs) and confirm Kokoro plays without fallback.
- Verify first audio starts after the first sentence completes (before full response finishes).

---

## 8. Implementation Notes

Chunking must respect Kokoro's token limit. If tokenization is not available at this layer, use a conservative cap (example: 240 characters) and split long sentences by punctuation or whitespace. This avoids the KokoroSwift hard error while retaining readability.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Sentence detection false positives (e.g., "Dr. Smith") | Use NLTokenizer which handles common abbreviations |
| Audio playback gaps between sentences | Use jitter buffer in AudioPlaybackService |
| Kokoro token overflow on long sentences | Apply conservative chunk size caps and split on whitespace/punctuation |
| Complexity vs. benefit | Defer unless user feedback indicates latency or long-response failures |

---

## 10. Decision: Defer for MVP

**Recommendation:** Keep as P2 unless long-response failures are frequent.

**Rationale:**
1. O.06 uses `StructuredGenerator` which produces full responses (no streaming).
2. Current batch TTS works well for typical response lengths.
3. Chunking adds non-trivial coordination for playback order and buffering.
4. The new token limit finding makes this more valuable, but still optional until user impact warrants prioritization.

---

## Implementation Summary
**Date:** 2026-01-06
**Branch:** `feat/X.03-reminders-tools`
**Commits:** 3

### Files Changed
- `Ora/TTS/SentenceChunker.swift` - add streaming sentence chunking with size caps.
- `Ora/LLM/ResponseTextStreamParser.swift` - stream response text out of JSON output.
- `Ora/LLM/StructuredGenerator.swift` - forward response tokens to a handler.
- `Ora/Orchestration/AgentLoop.swift` - delegate streaming response tokens.
- `Ora/Orchestration/SimplePipelineController.swift` - enqueue sentence chunks for TTS during streaming.
- `Ora/TTS/TTSService.swift` - synthesize per sentence chunk; add streaming entrypoint.
- `Ora/TTS/KokoroEngine.swift` - protocol extraction for testability.
- `OraTests/SentenceChunkerTests.swift` - chunker coverage.
- `OraTests/TTSServiceTests.swift` - long input splitting coverage.
- `OraTests/ResponseTextStreamParserTests.swift` - response parser streaming coverage.
- `docs/stories/tts-integration/T.03-SENTENCE-CHUNKER.md` - plan + acceptance updates.
- `docs/stories/README.md` - mark story complete.

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (`./build.sh`, `xcodebuild test -project Ora.xcodeproj -scheme Ora -only-testing OraTests/SentenceChunkerTests -only-testing OraTests/TTSServiceTests -only-testing OraTests/ResponseTextStreamParserTests`)
- [x] Working tree clean

## Completion Status
- [x] Implementation complete
- [x] Code review passed (3 iterations)
- [ ] PR merged: N/A
- [ ] Merged to main: N/A
- [x] Date: 2026-01-06

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-06T21:25:00Z
**Commit reviewed:** c75d08b
**Iteration:** 3

### Summary
- Files reviewed: 11
- Build status: Pass
- Tests status: Pass (18 tests)

### Issues Found

#### P0 - Critical (Must fix)
- [x] All P0 issues resolved.

#### P1 - Major (Should fix)
- [x] All P1 issues resolved.

#### P2 - Minor (Can defer)
- [x] All P2 issues resolved.

### Future Considerations (Out of Scope)
- None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
