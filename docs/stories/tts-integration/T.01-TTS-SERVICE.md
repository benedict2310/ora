# T.01 - TTS Service

**Epic:** TTS Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2 days
**Dependencies:** F.03 (Model Manager)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create a `TTSService` actor that wraps Kokoro MLX for local text-to-speech with streaming audio output.

---

## 2. Implementation

**File:** `Ora/TTS/TTSService.swift`

```swift
//
//  TTSService.swift
//  Ora
//
//  Kokoro TTS wrapper with fallback
//

import Foundation
import AVFoundation
import os

/// Audio chunk for playback
struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
    
    var duration: TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }
}

/// TTS service protocol
protocol TTSServicing: Sendable {
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>
    func stop() async
}

/// Kokoro-based TTS service with AVSpeech fallback
actor TTSService: TTSServicing {
    
    // MARK: - Singleton
    
    static let shared = TTSService()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "TTSService")
    
    private var kokoroEngine: KokoroEngine?
    private var isKokoroReady = false
    private var isSpeaking = false
    private var currentTask: Task<Void, Never>?
    
    // Fallback
    private let synthesizer = AVSpeechSynthesizer()
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Prepare TTS engine
    func prepare() async throws {
        guard !isKokoroReady else { return }
        
        logger.info("Preparing TTS engine...")
        
        // Get model path
        let modelManager = await ModelManager.shared
        guard let modelPath = await modelManager.pathForModel(.kokoro) else {
            logger.warning("Kokoro model not found, using fallback")
            return
        }
        
        do {
            kokoroEngine = try await KokoroEngine(modelPath: modelPath)
            isKokoroReady = true
            logger.info("Kokoro TTS ready")
        } catch {
            logger.error("Failed to load Kokoro: \(error.localizedDescription)")
            // Will use fallback
        }
    }
    
    /// Generate speech from text
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runSynthesis(text: text, continuation: continuation)
            }
            self.currentTask = task
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
    
    /// Stop current speech
    func stop() async {
        currentTask?.cancel()
        currentTask = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
        logger.debug("TTS stopped")
    }
    
    // MARK: - Private
    
    private func runSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        isSpeaking = true
        defer { isSpeaking = false }
        
        if isKokoroReady, let engine = kokoroEngine {
            await runKokoroSynthesis(text: text, engine: engine, continuation: continuation)
        } else {
            await runFallbackSynthesis(text: text, continuation: continuation)
        }
    }
    
    private func runKokoroSynthesis(
        text: String,
        engine: KokoroEngine,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        do {
            for try await samples in engine.synthesize(text: text) {
                try Task.checkCancellation()
                
                let chunk = AudioChunk(samples: samples, sampleRate: 24000)
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            logger.error("Kokoro synthesis failed: \(error.localizedDescription)")
            // Fall back to system TTS
            await runFallbackSynthesis(text: text, continuation: continuation)
        }
    }
    
    private func runFallbackSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        logger.info("Using AVSpeechSynthesizer fallback")
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        // Note: AVSpeechSynthesizer doesn't provide raw audio easily
        // For fallback, we just play directly
        synthesizer.speak(utterance)
        
        // Yield empty chunk to signal playback started
        continuation.yield(AudioChunk(samples: [], sampleRate: 24000))
        
        // Wait for completion
        while synthesizer.isSpeaking {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { break }
        }
        
        continuation.finish()
    }
}

// MARK: - Kokoro Engine (Placeholder)

/// Placeholder for Kokoro Swift MLX integration
actor KokoroEngine {
    init(modelPath: URL) async throws {
        // TODO: Initialize kokoro-swift-mlx
    }
    
    func synthesize(text: String) -> AsyncThrowingStream<[Float], Error> {
        // TODO: Implement with kokoro-swift-mlx
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
```

---

## 3. Acceptance Criteria

- [ ] **AC-1:** Kokoro model loads from ModelManager path
- [ ] **AC-2:** `speak()` returns `AsyncThrowingStream<AudioChunk, Error>`
- [ ] **AC-3:** Audio chunks stream as generated
- [ ] **AC-4:** Fallback to AVSpeechSynthesizer on failure
- [ ] **AC-5:** `stop()` cancels current synthesis
- [ ] **AC-6:** Sample rate is 24kHz (Kokoro default)

---

## 4. Implementation Checklist

- [ ] Add kokoro-swift-mlx dependency
- [ ] Create `TTSService.swift`
- [ ] Implement `KokoroEngine` wrapper
- [ ] Test streaming synthesis
- [ ] Test fallback behavior
- [ ] Measure time-to-first-audio
