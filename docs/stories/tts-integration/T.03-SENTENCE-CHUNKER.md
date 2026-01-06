# T.03 - Sentence Chunker

**Epic:** TTS Integration
**Status:** Not Started
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

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- `Ora/TTS/SentenceChunker.swift`

### 5.2 Files to Modify
- `Ora/Orchestration/SimplePipelineController.swift` - emit sentence chunks during streaming and queue them for TTS.
- `Ora/TTS/TTSService.swift` - accept per-sentence streaming and preserve ordering.
- `Ora/TTS/KokoroEngine.swift` - ensure long chunks are never passed through unbounded.

### 5.3 Tests to Add
- `OraTests/TTSServiceTests.swift` - ensure long inputs split and do not trigger Kokoro token overflow.
- `OraTests/SetupViewsTests.swift` (optional) - validate UI behavior for long streamed responses (if relevant).
- New `OraTests/SentenceChunkerTests.swift` - sentence boundary and size limit coverage.

---

## 6. Acceptance Criteria

- [ ] **AC-1:** Sentences extracted as they complete.
- [ ] **AC-2:** Remaining text flushed at end.
- [ ] **AC-3:** Handles streaming token input.
- [ ] **AC-4:** Uses NaturalLanguage for proper sentence detection.
- [ ] **AC-5:** Minimum sentence length filter to avoid tiny fragments.
- [ ] **AC-6:** Chunks stay under Kokoro token limit (no `KokoroTTSError.tooManyTokens`).
- [ ] **AC-7:** Integration with `SimplePipelineController` (speak sentence chunks during LLM streaming).

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
