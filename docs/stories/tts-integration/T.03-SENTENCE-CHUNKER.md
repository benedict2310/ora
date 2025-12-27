# T.03 - Sentence Chunker

**Epic:** TTS Integration
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 0.5 days
**Dependencies:** T.01, T.02
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Split streaming LLM text into sentences for early TTS start, enabling voice output before the full response is generated.

---

## 2. Implementation

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

## 3. Acceptance Criteria

- [ ] **AC-1:** Sentences extracted as they complete
- [ ] **AC-2:** Remaining text flushed at end
- [ ] **AC-3:** Handles streaming token input
- [ ] **AC-4:** Uses NaturalLanguage for proper sentence detection
- [ ] **AC-5:** Minimum sentence length filter

---

## 4. Implementation Checklist

- [ ] Create `SentenceChunker.swift`
- [ ] Test with streaming input
- [ ] Test edge cases (abbreviations, URLs)
- [ ] Integrate with TTS pipeline
