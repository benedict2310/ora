# A.02 - ASR Service

**Epic:** ASR Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** Parakeet S.01, S.03 (Core Engine, Streaming)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create an `ASRService` actor that wraps the Parakeet engine and conforms to Ora's `ASRServicing` protocol, providing streaming transcription.

---

## 2. Implementation

### 2.1 ASR Service

**File:** `Ora/ASR/ASRService.swift`

```swift
//
//  ASRService.swift
//  Ora
//
//  Parakeet ASR wrapper conforming to Ora protocols
//

import Foundation
import AVFoundation
import os

/// Events emitted during transcription
enum ASREvent: Sendable {
    case partial(text: String, stability: Float)
    case final(text: String)
}

/// ASR service protocol
protocol ASRServicing: Sendable {
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error>
    func reset() async
}

/// Parakeet-based ASR service
actor ASRService: ASRServicing {
    
    // MARK: - Singleton
    
    static let shared = ASRService()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ASRService")
    private var engine: ParakeetEngine?
    private var isReady = false
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Prepare the ASR engine (load models)
    func prepare() async throws {
        guard !isReady else { return }
        
        logger.info("Preparing ASR engine...")
        
        engine = ParakeetEngine()
        try await engine?.prepare()
        
        isReady = true
        logger.info("ASR engine ready")
    }
    
    /// Transcribe audio frames to text events
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runTranscription(frames: frames, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Reset decoder state for new session
    func reset() async {
        await engine?.reset()
        logger.debug("ASR decoder reset")
    }
    
    // MARK: - Private
    
    private func runTranscription(
        frames: AsyncStream<AudioFrame>,
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation
    ) async throws {
        guard isReady, let engine = engine else {
            throw ASRServiceError.notReady
        }
        
        var accumulatedSamples: [Float] = []
        var lastPartialText = ""
        
        // Process frames as they arrive
        for await frame in frames {
            accumulatedSamples.append(contentsOf: frame.samples)
            
            // Process when we have enough audio (160ms = 2560 samples at 16kHz)
            if accumulatedSamples.count >= 2560 {
                let partial = try await engine.process(
                    samples: accumulatedSamples,
                    language: "en"
                )
                
                if let partial = partial, partial.text != lastPartialText {
                    lastPartialText = partial.text
                    continuation.yield(.partial(text: partial.text, stability: 0.8))
                }
            }
        }
        
        // Finalize with remaining audio
        if !accumulatedSamples.isEmpty {
            let final = try await engine.finalize(
                samples: accumulatedSamples,
                language: "en"
            )
            
            if let final = final, !final.text.isEmpty {
                continuation.yield(.final(text: final.text))
            }
        }
        
        continuation.finish()
    }
}

// MARK: - Errors

enum ASRServiceError: LocalizedError {
    case notReady
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notReady:
            return "ASR engine is not ready. Please wait for model loading."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
```

---

## 3. Acceptance Criteria

- [ ] **AC-1:** `ASRService` conforms to `ASRServicing` protocol
- [ ] **AC-2:** `transcribe()` returns `AsyncThrowingStream<ASREvent, Error>`
- [ ] **AC-3:** Partial events emitted during speech
- [ ] **AC-4:** Final event emitted when stream ends
- [ ] **AC-5:** `reset()` clears decoder state
- [ ] **AC-6:** Handles empty audio gracefully

---

## 4. Implementation Checklist

- [ ] Create `ASRService.swift`
- [ ] Integrate with ParakeetEngine from S.01
- [ ] Test partial emission rate
- [ ] Test final transcription accuracy
- [ ] Add error handling for model load failures
