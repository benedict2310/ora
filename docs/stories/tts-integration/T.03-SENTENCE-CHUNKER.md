# T.03 - Sentence Chunker

**Epic:** TTS Integration
**Status:** Not Started
**Priority:** P2 (Nice to Have)
**Estimated Effort:** 0.5 days
**Dependencies:** T.01, T.02, O.03
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Split streaming LLM text into sentences for early TTS start, enabling voice output before the full response is generated.

---

## 2. Current State (Post O.03)

As of O.03, TTS is integrated but works in a **batch mode**:
1. LLM streams tokens → `currentResponse` accumulates in `SimplePipelineController`
2. LLM finishes → `handleCompletion()` → `speakResponse(currentResponse)`  
3. TTS speaks the **entire response at once**

This means TTS doesn't start until the LLM has finished generating the complete response.

### Why Sentence Chunking Helps

For longer responses, the user waits for the full LLM generation before hearing anything. With sentence chunking:
- TTS can start speaking the first sentence while the LLM is still generating
- Perceived latency is reduced (first audio ~500ms after first sentence completes)
- More natural conversational feel

### When This Matters Less

- Short responses (1-2 sentences): Minimal benefit since LLM finishes quickly
- AgentLoop responses: StructuredGenerator produces full response, no token streaming
- Current implementation is fine for MVP

---

## 3. Implementation

**File:** `Ora/TTS/SentenceChunker.swift`

```swift
//
//  SentenceChunker.swift
//  Ora
//
//  Splits streaming text into sentences for early TTS
//

import Foundation
import NaturalLanguage

/// Chunks streaming text into sentences
struct SentenceChunker: Sendable {
    
    private let minSentenceLength = 10  // Avoid tiny fragments
    
    /// Process streaming tokens into sentence chunks
    func chunk(tokens: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var buffer = ""
                
                do {
                    for try await token in tokens {
                        buffer += token
                        
                        // Check for sentence boundaries
                        let sentences = extractCompleteSentences(from: &buffer)
                        for sentence in sentences {
                            continuation.yield(sentence)
                        }
                    }
                    
                    // Yield any remaining text
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        continuation.yield(trimmed)
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Extract complete sentences from buffer, leaving incomplete text
    private func extractCompleteSentences(from buffer: inout String) -> [String] {
        var sentences: [String] = []
        
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = buffer
        
        var lastEnd: String.Index = buffer.startIndex
        
        tokenizer.enumerateTokens(in: buffer.startIndex..<buffer.endIndex) { range, _ in
            let sentence = String(buffer[range])
            
            // Check if this looks like a complete sentence
            if isCompleteSentence(sentence) && sentence.count >= minSentenceLength {
                sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
                lastEnd = range.upperBound
            }
            
            return true
        }
        
        // Remove processed text from buffer
        if lastEnd > buffer.startIndex {
            buffer = String(buffer[lastEnd...])
        }
        
        return sentences
    }
    
    private func isCompleteSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        // Check for sentence-ending punctuation
        let endings = [".", "!", "?", "。", "！", "？"]
        return endings.contains { trimmed.hasSuffix($0) }
    }
}
```

---

## 4. Acceptance Criteria

- [ ] **AC-1:** Sentences extracted as they complete
- [ ] **AC-2:** Remaining text flushed at end
- [ ] **AC-3:** Handles streaming token input
- [ ] **AC-4:** Uses NaturalLanguage for proper sentence detection
- [ ] **AC-5:** Minimum sentence length filter
- [ ] **AC-6:** Integration with SimplePipelineController (speakSentence during LLM streaming)

---

## 5. Integration with SimplePipelineController

To integrate sentence chunking, modify `processTranscript()` to start TTS per-sentence:

```swift
// In processTranscript(), replace the token accumulation loop:

var fullResponse = ""
var sentenceBuffer = ""
let chunker = SentenceChunker()

for try await delta in await LLMService.shared.generate(messages: messages, maxTokens: 500) {
    guard !Task.isCancelled else { return }
    
    if case .token(let text) = delta {
        fullResponse += text
        sentenceBuffer += text
        self.currentResponse = fullResponse
        OverlayWindowController.shared.model.addAssistantMessage(fullResponse, isPartial: true)
        
        // Check for complete sentences
        let sentences = chunker.extractCompleteSentences(from: &sentenceBuffer)
        for sentence in sentences {
            // Queue sentence for TTS (don't await - let it play in background)
            self.queueSentenceForSpeaking(sentence)
        }
    }
}

// Speak any remaining text
if !sentenceBuffer.isEmpty {
    self.queueSentenceForSpeaking(sentenceBuffer)
}
```

**Note:** This requires changes to the TTS queueing to handle multiple sentences in flight. Consider deferring to a future optimization pass.

---

## 6. Implementation Checklist

- [ ] Create `SentenceChunker.swift`
- [ ] Add synchronous `extractCompleteSentences(from:)` method for in-line use
- [ ] Test with streaming input
- [ ] Test edge cases (abbreviations, URLs, "Dr.", "Mr.", numbers like "3.5")
- [ ] Update SimplePipelineController to use chunker during LLM streaming
- [ ] Add sentence queue to AudioPlaybackService (or SimplePipelineController)
- [ ] Ensure TTS playback order is preserved

---

## 7. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Sentence detection false positives (e.g., "Dr. Smith") | Use NLTokenizer which handles common abbreviations |
| Audio playback gaps between sentences | Use jitter buffer in AudioPlaybackService |
| Complexity vs. benefit | Defer until user feedback indicates latency is an issue |

---

## 8. Decision: Defer for MVP

**Recommendation:** Mark as P2 and defer until after O.06 (AgentLoop Integration).

**Rationale:**
1. O.06 uses `StructuredGenerator` which produces full responses (no streaming)
2. Current batch TTS works well for typical response lengths
3. Focus on core tool execution flow first
4. Can revisit if user feedback indicates perceived latency is problematic
