# T.02 - Audio Playback

**Epic:** TTS Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** T.01 (TTS Service)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create an `AudioPlaybackService` that manages streaming audio playback with buffering and clean interruption.

---

## 2. Implementation

**File:** `Ora/TTS/AudioPlaybackService.swift`

```swift
//
//  AudioPlaybackService.swift
//  Ora
//
//  Manages audio playback queue
//

import Foundation
import AVFoundation
import os

/// Audio playback service
actor AudioPlaybackService {
    
    // MARK: - Singleton
    
    static let shared = AudioPlaybackService()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "AudioPlayback")
    
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isPlaying = false
    
    // Buffer management
    private let targetBufferDuration: TimeInterval = 0.8  // 800ms jitter buffer
    private var bufferedDuration: TimeInterval = 0
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Start playback engine
    func prepare() throws {
        guard engine == nil else { return }
        
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        engine.attach(playerNode)
        
        // Connect with output format
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!
        
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        try engine.start()
        
        self.engine = engine
        self.playerNode = playerNode
        
        logger.info("Audio playback engine ready")
    }
    
    /// Play audio chunks as they arrive
    func play(chunks: AsyncThrowingStream<AudioChunk, Error>) async throws {
        guard let playerNode = playerNode else {
            throw AudioPlaybackError.notPrepared
        }
        
        isPlaying = true
        bufferedDuration = 0
        
        playerNode.play()
        
        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                
                guard !chunk.samples.isEmpty else { continue }
                
                // Convert to buffer
                guard let buffer = createBuffer(from: chunk) else { continue }
                
                // Schedule for playback
                playerNode.scheduleBuffer(buffer) {
                    Task { await self.onBufferComplete(duration: chunk.duration) }
                }
                
                bufferedDuration += chunk.duration
                
                // Throttle if buffer is getting too large
                while bufferedDuration > targetBufferDuration * 2 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            
            // Wait for playback to complete
            await waitForPlaybackComplete()
            
        } catch is CancellationError {
            logger.debug("Playback cancelled")
        }
        
        isPlaying = false
    }
    
    /// Stop playback immediately
    func stop() {
        playerNode?.stop()
        bufferedDuration = 0
        isPlaying = false
        logger.debug("Playback stopped")
    }
    
    // MARK: - Private
    
    private func createBuffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(chunk.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        
        let frameCount = AVAudioFrameCount(chunk.samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        chunk.samples.withUnsafeBufferPointer { source in
            guard let dest = buffer.floatChannelData?[0] else { return }
            memcpy(dest, source.baseAddress!, chunk.samples.count * MemoryLayout<Float>.stride)
        }
        
        return buffer
    }
    
    private func onBufferComplete(duration: TimeInterval) {
        bufferedDuration -= duration
    }
    
    private func waitForPlaybackComplete() async {
        while bufferedDuration > 0 && isPlaying {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - Errors

enum AudioPlaybackError: LocalizedError {
    case notPrepared
    
    var errorDescription: String? {
        "Audio playback not prepared. Call prepare() first."
    }
}
```

---

## 3. Acceptance Criteria

- [ ] **AC-1:** AVAudioEngine configured for playback
- [ ] **AC-2:** Chunks scheduled as they arrive
- [ ] **AC-3:** Jitter buffer prevents underruns
- [ ] **AC-4:** `stop()` clears queue immediately
- [ ] **AC-5:** Waits for completion before returning

---

## 4. Implementation Checklist

- [ ] Create `AudioPlaybackService.swift`
- [ ] Test streaming playback
- [ ] Test interruption handling
- [ ] Measure buffer levels
