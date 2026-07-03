# ASR Integration Epic

Integrate FluidAudio Parakeet ASR engine with Ora's audio pipeline and UI.

## Overview

This epic bridges the Parakeet starter stories with Ora's application architecture, providing:
- Audio capture coordinated with PTT hotkey
- Real-time streaming transcription
- Partial/final transcript delivery to UI
- Integration with the orchestration layer

## Prerequisites

- **Foundations:** F.01, F.05 (App Shell, Hotkey)
- **Parakeet Starter:** S.01, S.02, S.03 (Core Engine, Audio Capture, Streaming)

## Story Index

| Story | Title | Description | Dependencies | Status |
|-------|-------|-------------|--------------|--------|
| **A.01** | [Audio Service](A.01-AUDIO-SERVICE.md) | Wrap audio capture with PTT lifecycle | F.05, S.02 | ✅ Complete |
| **A.02** | [ASR Service](A.02-ASR-SERVICE.md) | Wrap Parakeet engine with Ora protocols | S.01, S.03 | ✅ Complete |
| **A.03** | [Transcript Stream](A.03-TRANSCRIPT-STREAM.md) | Connect ASR to UI and orchestrator | A.01, A.02, F.07 | ✅ Complete |

## Dependency Graph

```
Parakeet S.01-S.03 ──┐
                     │
F.05 (Hotkey) ───────┼──► A.01 (Audio Service)
                     │          │
                     └──► A.02 (ASR Service)
                                │
F.07 (Overlay) ─────────► A.03 (Transcript Stream)
```

## Architecture Alignment

From `ARCHITECTURE.md`:
```
[AudioPipeline actor]
  |-->[AVAudioEngine Capture + RingBuffer]
  \-->[ASRService] (FluidAudio Parakeet streaming) ---> partial transcript stream
```

## Key Interfaces

```swift
// From ARCHITECTURE.md
protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async
    var frames: AsyncStream<AudioFrame> { get }
}

protocol ASRServicing: Sendable {
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error>
}

enum ASREvent: Sendable {
    case partial(text: String, stability: Float)
    case final(text: String)
    case endOfSpeech
}
```

## Success Criteria

- [x] Audio capture starts on hotkey press
- [x] Audio capture stops on hotkey release
- [x] Partial transcripts stream to overlay UI
- [x] Final transcript sent to orchestrator on release
- [ ] < 400ms latency for first partial (pending performance testing)
- [x] Clean cancellation on user interrupt

## Epic Status: ✅ Complete

All 3 stories implemented and merged to main.
