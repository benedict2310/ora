# TTS Integration Epic

Integrate Kokoro MLX for local text-to-speech synthesis.

## Overview

This epic provides voice output for Ora using Kokoro TTS:
- Model loading and warmup
- Streaming audio generation
- Sentence-level chunking for early playback
- AVSpeechSynthesizer fallback
- Audio playback management

## Prerequisites

- **Foundations:** F.03 (Model Manager)

## Story Index

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **T.01** | [TTS Service](T.01-TTS-SERVICE.md) | Kokoro wrapper, audio generation | F.03 |
| **T.02** | [Audio Playback](T.02-AUDIO-PLAYBACK.md) | Queue management, streaming playback | T.01 |
| **T.03** | [Sentence Chunker](T.03-SENTENCE-CHUNKER.md) | Split text for early audio start | T.01, T.02 |
| **T.04** | [Chunker Content Handling](T.04-CHUNKER-CONTENT-HANDLING.md) | Fix content loss for markdown/lists | T.03 |
| **T.05** | [TTS Interruption UX](T.05-TTS-INTERRUPTION-UX.md) | Stop speaking without closing overlay | T.02 |

## Dependency Graph

```
F.03 (Model Manager) ──► T.01 (TTS Service)
                              │
                              ├──► T.02 (Audio Playback)
                              │        │
                              │        └──► T.05 (TTS Interruption UX)
                              │
                              └──► T.03 (Sentence Chunker)
                                         │
                                         └──► T.04 (Chunker Content Handling)
```

## Architecture Alignment

From `ARCHITECTURE.md`:
```
[TTSEngine actor] (Kokoro MLX) ---> audio chunk stream ---> [AudioPlayback actor]
        |                              \---> [AVSpeechSynthesizer fallback]
```

## Key Interfaces

```swift
protocol TTSServicing: Sendable {
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>
}

struct AudioChunk: Sendable {
    let pcmFloat32: [Float]
    let sampleRate: Int
}
```

## Model Configuration

| Model | Size | Performance |
|:------|:-----|:------------|
| Kokoro 82M (bf16) | ~500MB | ~3.3x real-time on M-series |

## Success Criteria

- [x] TTS audio starts within ~500ms for short responses (0.28s model init + 0.82x RTF)
- [x] Streaming playback with no underruns (T.02)
- [x] Graceful fallback to AVSpeechSynthesizer
- [x] Text always shown in UI (regardless of TTS status)
- [x] Clean interrupt on user cancellation (T.02)

## Status

| Story | Status |
|:------|:-------|
| T.01 - TTS Service | ✅ Complete (Kokoro + AVSpeech fallback) |
| T.02 - Audio Playback | ✅ Complete (jitter buffer, streaming) |
| T.03 - Sentence Chunker | ✅ Complete (basic implementation) |
| T.04 - Chunker Content Handling | 🚧 In Progress (Phase 2 complete) |
| T.05 - TTS Interruption UX | ✅ Complete |

## Notes

- **O.03 (Conversation Orchestrator)** integrated TTS into the voice pipeline
- TTS currently works in batch mode (speaks after LLM completes)
- T.03 would enable streaming TTS (speak while LLM generates) but is deferred until user feedback indicates need
