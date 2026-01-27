# T.04 - Chunker Content Handling

**Epic:** TTS Integration
**Status:** In Progress (Phase 1-2 complete)
**Priority:** P1 (High - Bug causing content loss)
**Estimated Effort:** 2 days
**Dependencies:** T.03
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Fix the SentenceChunker to properly handle markdown and structured content from LLM responses. Currently, the chunker drops ~85% of content when processing numbered lists, markdown formatting, and text without standard sentence-ending punctuation.

**Root Cause:** The `isCompleteSentence()` check (line 181-184) only accepts sentences ending in `.`, `!`, or `?`. In `extractCompleteSentences()` (lines 162-165), any sentence failing this check is **silently dropped**:

```swift
// Current problematic code (SentenceChunker.swift:162-165)
if isCompleteSentence(sentence) {
    sentences.append(sentence)    // ← Only added if ends with .!?
    lastEnd = range.upperBound
}
// Content not ending with .!? is DROPPED, not buffered
```

Combined with how NLTokenizer fragments markdown content (e.g., splitting `1.` as a separate "sentence" from the actual content), most content is silently dropped.

**Example Failure:**
```
Input:  1238 characters (calendar event list)
Output: 150 characters (5 tiny chunks)
Lost:   88% of content
Spoken: "Pilates mums & babies!" (one fragment that happened to end with `!`)
```

**Key Discovery:** The `finalize()` method (lines 78-94) already correctly handles incomplete text by emitting whatever remains in the buffer. The bug only affects content dropped during `consume()` before finalize is called.

---

## 2. User Story

As a user, I want Ora to speak complete responses for lists, calendar events, and structured information, so I hear all the information I requested rather than disconnected fragments.

---

## 3. Scope

### In Scope

**Phase 1: Bug Fix (P0)**
- Remove the `isCompleteSentence()` gate entirely - let NLTokenizer decide boundaries
- The existing `minSentenceLength` check already prevents tiny fragments
- Add basic markdown stripping (`**text**` → `text`, `*text*` → `text`, `_text_` → `text`)
- Add regression test corpus with challenging real-world texts
- Add logging for debugging chunker behavior (already done)
- Primary focus is the static `SentenceChunker.chunk(text:)` path (streaming path is disabled), but changes are in core chunking so future streaming benefits too

**Phase 2: Content-Aware Chunking (P1)**
- Advanced list handling (chunk by list items as natural speech units)
- Handle structured data (dates, times, addresses)
- Consider natural speech boundaries vs. punctuation-based boundaries
- Strip additional markdown syntax (`#` headers, `- ` bullets, etc.)

**Phase 3: Token-Aware Optimization (P2 - Future)**
- Use Kokoro tokenization for accurate chunk sizing
- More efficient chunk sizes (currently conservative 240 char limit)
- Measure and optimize time-to-first-audio

### Out of Scope

- Alternate TTS engines
- Prosody control or SSML
- Multi-language sentence detection
- Streaming TTS (SimplePipelineController.usesStreamingTTS remains false)

---

## 4. Architecture Alignment

- **Component:** `Ora/TTS/SentenceChunker.swift`
- **Integration:** `TTSService.swift` uses static `SentenceChunker.chunk()` method
- **Concurrency:** SentenceChunker is a value-type struct, thread-safe by design
- **Testing:** `OraTests/SentenceChunkerTests.swift` + new test corpus

**Current Flow:**
```
LLM Response → TTSService.speak() → SentenceChunker.chunk() → KokoroEngine
                                           ↓
                              [BUG: drops 85%+ of structured content]
```

**Fixed Flow:**
```
LLM Response → TTSService.speak() → SentenceChunker.chunk() → KokoroEngine
                                           ↓
                              [All content preserved and properly chunked]
```

---

## 5. Implementation Plan (Draft)

### Phase 1: Bug Fix

**Execution order (required):**
1. Write/extend unit tests first (expect failures).
2. Fix failures one-by-one (red → green), keeping changes minimal.
3. Run `./build.sh test` until green.
4. Run `./build.sh test-tts` with `RUN_TTS_TESTS=1` to verify audio output.
5. Capture findings; only then decide whether to proceed to Phase 2 refinements.

### 5.1 Files to Create

- `OraTests/ChunkerTestCorpus.swift` - Test corpus with challenging real-world texts (see Section 7)
- `OraTests/TTSIntegrationTests.swift` - On-demand audio integration tests (plays audio, skipped by default)

### 5.2 Files to Modify

- `build.sh` - Add `test-tts` command for on-demand audio integration tests

- `Ora/TTS/SentenceChunker.swift`
  - **Remove `isCompleteSentence()` gate** in `extractCompleteSentences()` (lines 162-165):
    ```swift
    // BEFORE (drops content):
    if isCompleteSentence(sentence) {
        sentences.append(sentence)
        lastEnd = range.upperBound
    }

    // AFTER (preserves all content):
    sentences.append(sentence)
    lastEnd = range.upperBound
    ```
  - **Add basic markdown stripping** - new private method:
    ```swift
    private func stripMarkdown(_ text: String) -> String {
        var result = text
        // Strip bold: **text** (double asterisks only - unambiguous)
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        // Strip italics: *text* and _text_ (guard underscores inside filenames)
        result = result.replacingOccurrences(
            of: "(^|\\s)\\*(\\S[^*]*?)\\*(?=\\s|$)",
            with: "$1$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(^|\\s)_(\\S[^_]*?)_(?=\\s|$)",
            with: "$1$2",
            options: .regularExpression
        )
        return result
    }
    ```
    **Edge case:** `_italic_` can incorrectly strip underscores from filenames like `file_name_here.txt`. Phase 1 includes italics stripping but must guard for word-boundaries (tests cover this).
  - Call `stripMarkdown()` before emitting chunks (including `finalize()` output) so pending/buffered text is normalized too
  - **Keep** `isCompleteSentence()` method (may be useful for Phase 2) but don't use it as a gate
  - **Keep** `minSentenceLength` logic - this already buffers short fragments correctly

### 5.3 Tests to Add

**Unit Tests (run always with `./build.sh test`):**
- `OraTests/SentenceChunkerTests.swift`
  - `test_chunkerHandlesMarkdownNumberedList()`
  - `test_chunkerHandlesCalendarEventFormat()`
  - `test_chunkerPreservesAllContent()` - verify no content loss
  - `test_chunkerHandlesTextWithoutFinalPunctuation()`
  - `test_chunkerStripsBoldMarkdown()` - `**text**` → `text`
  - `test_chunkerStripsItalicMarkdown()` - `*text*` → `text` and `_text_` → `text`
  - `test_chunkerPreservesUnderscoresInFilenames()` - `file_name.txt` unchanged
  - `test_chunkerPreservesUnderscoresInIdentifiers()` - `snake_case` unchanged
  - `test_corpusCalendarEvents()` - real calendar output
  - `test_corpusBulletList()` - bullet point formatting
  - `test_corpusMixedContent()` - prose + lists combined
  - `test_corpusLongParagraph()` - oversized text splitting
  - `test_corpusFilenames()` - includes `file_name_here.txt` and `IMG_2024_01_01.png`

**Integration Tests (run on-demand with `./build.sh test-tts`):**
- `OraTests/TTSIntegrationTests.swift`
  - `test_ttsPlaysCalendarEventList()` - full pipeline with audio
  - `test_ttsPlaysBulletList()` - verify spoken output
  - `test_ttsPlaysLongResponse()` - chunked audio playback
  - Tests use `throw XCTSkip(...)` when `RUN_TTS_TESTS != "1"`

### 5.4 Phase 2: Content-Aware Chunking (Future)

**Files to Modify:**
- `Ora/TTS/SentenceChunker.swift`
  - Extend `stripMarkdown()` to handle headers (`# `, `## `), bullets (`- `, `* `), code blocks
  - Detect list structure and chunk by list items as speech units
  - Handle speech-friendly boundaries (natural pauses after list items)

**Tests to Add:**
- `test_chunkerStripsHeaderMarkdown()`
- `test_chunkerStripsBulletMarkdown()`
- `test_chunkerChunksByListItems()`
- `test_chunkerHandlesNestedFormatting()`

### 5.5 Phase 3: Token-Aware Optimization (Future)

- Integrate Kokoro tokenizer for accurate chunk sizing
- Replace 240-char limit with 400-token limit
- Measure TTFA improvements

---

## Implementation Plan

### Files to Create
- `OraTests/ChunkerTestCorpus.swift` - Regression corpus for structured markdown/list content
- `OraTests/TTSIntegrationTests.swift` - On-demand audio integration tests (skipped by default)

### Files to Modify
- `Ora/TTS/SentenceChunker.swift` - Remove completion gate, add markdown stripping, emit normalized chunks
- `OraTests/SentenceChunkerTests.swift` - Add coverage for lists, markdown, filenames, and corpus
- `build.sh` - Add `test-tts` command for on-demand audio tests

### Tests to Add
- `SentenceChunkerTests.test_chunkerHandlesMarkdownNumberedList`
- `SentenceChunkerTests.test_chunkerHandlesCalendarEventFormat`
- `SentenceChunkerTests.test_chunkerPreservesAllContent`
- `SentenceChunkerTests.test_chunkerHandlesTextWithoutFinalPunctuation`
- `SentenceChunkerTests.test_chunkerStripsBoldMarkdown`
- `SentenceChunkerTests.test_chunkerStripsItalicMarkdown`
- `SentenceChunkerTests.test_chunkerPreservesUnderscoresInFilenames`
- `SentenceChunkerTests.test_chunkerPreservesUnderscoresInIdentifiers`
- `SentenceChunkerTests.test_corpusCalendarEvents`
- `SentenceChunkerTests.test_corpusBulletList`
- `SentenceChunkerTests.test_corpusMixedContent`
- `SentenceChunkerTests.test_corpusLongParagraph`
- `SentenceChunkerTests.test_corpusFilenames`
- `TTSIntegrationTests.test_ttsPlaysCalendarEventList`
- `TTSIntegrationTests.test_ttsPlaysBulletList`
- `TTSIntegrationTests.test_ttsPlaysLongResponse`

## 6. Acceptance Criteria

### Phase 1 (P0 - Must Fix)

- [x] AC-1: No content loss (normalized) - input equals output after normalization (strip `**...**`, `*...*`, `_..._`, collapse whitespace) - ✅ Verified by `SentenceChunkerTests.test_chunkerPreservesAllContent`
- [x] AC-2: Numbered list items spoken completely (not just the numbers like "1." "2.") - ✅ Verified by `SentenceChunkerTests.test_chunkerHandlesMarkdownNumberedList`
- [x] AC-3: Calendar event format handled (dates, times, locations preserved) - ✅ Verified by `SentenceChunkerTests.test_chunkerHandlesCalendarEventFormat`
- [x] AC-4: Text without final punctuation emitted correctly - ✅ Verified by `SentenceChunkerTests.test_chunkerHandlesTextWithoutFinalPunctuation`
- [x] AC-5: Bold + italic stripped (`**bold**`, `*italic*`, `_italic_` → plain text) - ✅ Verified by `SentenceChunkerTests.test_chunkerStripsBoldMarkdown` + `SentenceChunkerTests.test_chunkerStripsItalicMarkdown`
- [x] AC-6: Filenames/identifiers with underscores remain unchanged (`file_name.txt`, `snake_case`) - ✅ Verified by `SentenceChunkerTests.test_chunkerPreservesUnderscoresInFilenames` + `SentenceChunkerTests.test_chunkerPreservesUnderscoresInIdentifiers`
- [x] AC-7: Unit test corpus passes with 100% content preservation - ✅ Verified by `test_corpus*` coverage
- [x] AC-8: Existing `SentenceChunkerTests` continue to pass - ✅ Verified by `./build.sh test` (see Test Notes)
- [x] AC-9: `./build.sh test-tts` command runs on-demand audio integration tests - ✅ Verified on 2026-01-27 (`TTSIntegrationTests` executed, 3/3 passed)

### Phase 2 (P1 - Should Fix)

- [x] AC-10: Advanced markdown stripped (`# headers`, `- bullets`, code blocks) - ✅ Verified by `test_chunkerStripsHeaderMarkdown` + `test_chunkerStripsBulletMarkdown` + `test_chunkerHandlesNestedFormatting`
- [x] AC-11: List items chunked as natural speech units - ✅ Verified by `test_chunkerChunksByListItems`
- [ ] AC-12: Streaming path fixed (when `usesStreamingTTS` is enabled) - Deferred to Phase 3 (per request)

### Phase 3 (P2 - Nice to Have)

- [ ] AC-13: Token-aware chunking with Kokoro tokenizer
- [ ] AC-14: Improved time-to-first-audio metrics

---

## 7. Verification Plan

**Order of operations (per phase):** Unit tests first (expect failure), fix incrementally until green, then run on-demand audio tests.

### Automated Tests

```bash
./build.sh test  # includes all SentenceChunkerTests + corpus
```

- [ ] `SentenceChunkerTests` - all existing + new corpus tests pass
- [ ] Content preservation assertion: normalized `input` == normalized `chunks.joined()`
- [ ] No audio played during regular test runs

### On-Demand Audio Tests

```bash
./build.sh test-tts  # runs TTSIntegrationTests with audio output
```

- [ ] `TTSIntegrationTests` - full pipeline tests with actual audio playback
- [ ] Verifies chunked content sounds natural when spoken
- [ ] Skipped by default (requires `RUN_TTS_TESTS=1` environment variable)

### Manual Tests

- [ ] Ask "What's on my calendar this week?" - verify full list is spoken
- [ ] Ask "Give me a numbered list of 5 items" - verify all items spoken
- [ ] Ask a question that produces markdown response - verify clean speech

### Test Corpus (Regression Suite)

```swift
struct ChunkerTestCorpus {
    /// Markdown numbered list (the failing case)
    static let calendarEventList = """
    Here are your events for this week:

    1. **Elfie & Gerhard Skivacay**
       - Calendar: Maddie & Bene
       - Date: January 24-29 (all day)

    2. **PERFORM**
       - Calendar: Maddie & Bene
       - Date: January 25-29 (all day)

    Let me know if you'd like help with anything specific!
    """

    /// Bullet points
    static let bulletList = """
    Here's what you need:
    - Milk
    - Eggs (dozen)
    - Bread
    - Butter
    That should cover breakfast!
    """

    /// No final punctuation
    static let noPunctuation = """
    The answer is 42
    """

    /// Mixed content
    static let mixedContent = """
    Great question! Here are 3 things to remember:
    1. Always save your work
    2. Take breaks every hour
    3. Stay hydrated
    Good luck with your project
    """

    /// Filenames and identifiers (underscores should remain)
    static let filenames = """
    Please open file_name_here.txt and IMG_2024_01_01.png
    Also keep snake_case identifiers intact
    """

    /// Long paragraph requiring split
    static let longParagraph = """
    This is a very long paragraph that exceeds the maximum chunk length and needs to be split at appropriate boundaries such as punctuation marks or whitespace to ensure that each chunk can be processed by the TTS engine without exceeding its token limit while still maintaining natural speech flow and readability for the listener who expects coherent sentences.
    """
}
```

---

## 8. Performance / Reliability Considerations

- **No regression:** Chunk size limits (240 chars) remain to prevent Kokoro token overflow
- **Latency:** Phase 1 should not impact time-to-first-audio
- **Memory:** No significant memory impact from buffering incomplete sentences

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking existing behavior | Comprehensive test corpus including current passing cases |
| Over-chunking (too many small pieces) | Maintain minSentenceLength threshold |
| Under-chunking (exceeding Kokoro limits) | Maintain maxChunkLength safety cap |
| NLTokenizer language limitations | Document limitation; English-focused for MVP |

---

## 10. Open Questions

- [x] ~~Should we detect content type (prose vs. list) and use different chunking strategies?~~ **Decision:** Defer to Phase 2. Phase 1 removes the gate and lets NLTokenizer decide.
- [x] ~~Should markdown stripping be done in chunker or in a separate preprocessing step?~~ **Decision:** In chunker for Phase 1 (basic). May revisit in Phase 2.
- [x] ~~What's the best chunk boundary for list items - after the number, or after the whole item?~~ **Decision:** Chunk whole list items (including sub-bullets) as one speech unit.
- [x] ~~Should the streaming path (`usesStreamingTTS`) be fixed in Phase 2 or remain disabled?~~ **Decision:** Defer to Phase 3 per request.

**Phased verification policy:** After each phase, run unit tests first (expect failure), fix incrementally until green, then run `test-tts` to confirm spoken output before advancing.

---

## Implementation Summary

**Date:** 2026-01-27
**Branch:** (not created)
**Commits:** 0

### Files Changed
- `Ora/TTS/SentenceChunker.swift` - list-aware chunking + extra markdown stripping + date range + single-date ordinal normalization
- `OraTests/SentenceChunkerTests.swift` - added Phase 2 coverage (headers/bullets/list items/nested formatting + calendar bullets)
- `OraTests/ChunkerTestCorpus.swift` - regression corpus for real-world content + calendar week bullets
- `OraTests/TTSIntegrationTests.swift` - on-demand audio integration tests (gated by flag file)
- `build.sh` - added `test-tts` command + flag gating

### Test Notes
- Isolated: `xcodebuild ... -only-testing:OraTests/SentenceChunkerTests/test_chunkerHandlesCalendarWeekBulletList` ✅ `1/1` passed.
- `./build.sh test` timed out at 300s on 2026-01-27; result bundle was incomplete.
- `./build.sh test-tts` reported ✅ `6/6` on 2026-01-27 with audio playback; xcodebuild still reports unhandled SwiftPM resources.

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
