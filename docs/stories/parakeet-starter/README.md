# Parakeet Starter Pack

A comprehensive set of implementation stories for building a macOS transcription app using **Parakeet** (Apple Neural Engine via FluidAudio/Core ML).

## Overview

This starter pack provides 5 detailed implementation stories that guide you through building a complete, production-ready voice transcription system. Stories are organized into v1 (MVP) and v2 (enhancements).

## Story Index

### v1 Stories (MVP - PTT Mode)

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **S.01** | [Core Engine Integration](S.01-CORE-ENGINE-INTEGRATION.md) | Parakeet engine setup, model downloading, ASREngine protocol | None |
| **S.02** | [Audio Capture Pipeline](S.02-AUDIO-CAPTURE-PIPELINE.md) | Microphone capture, format conversion, ring buffer | S.01 |
| **S.03** | [Real-Time Streaming](S.03-REALTIME-STREAMING-TRANSCRIPTION.md) | Streaming manager, text diffing (PTT finalization for v1) | S.01, S.02 |

### v2 Stories (Enhancements)

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **S.04** | [Transcription Control](S.04-TRANSCRIPTION-CONTROL.md) | State machine, session management, VAD-based EOU | S.01, S.02, S.03 |
| **S.05** | [Always-On Mode](S.05-ALWAYS-ON-CONTINUOUS-LISTENING.md) | Continuous listening, minutes pad, retroactive transcription | S.01, S.02, S.03, S.04 |

### v1 Implementation Notes

For v1 (PTT-only mode):
- **S.03 simplification:** Finalization triggered by PTT release (hotkey up), not VAD/EOU detection
- **S.04 deferral:** Full state machine with VAD-based EOU is v2
- **S.05 deferral:** Always-on continuous listening is v2

## Features Included

- **Real-time transcription** with sub-400ms latency
- **Turn transcription on/off** with clean state management
- **Always-on mode** for continuous listening and retroactive transcription (v2)
- **Voice Activity Detection (VAD)** for CPU efficiency (v2 for EOU, optional for v1)
- **Streaming partials** with text diffing for stable output

## Features Excluded

This starter pack intentionally omits:
- Whisper support (Parakeet-only)
- Clipboard integration
- Auto-paste functionality
- HUD/visualization components

These can be added as extensions after the core functionality is working.

---

## Dependency Graph

### v1 (MVP)
```
S.01 (Core Engine)
  ↓
S.02 (Audio Capture)
  ↓
S.03 (Streaming) [PTT finalization]
```

### v2 (Full)
```
S.01 (Core Engine)
  ↓
S.02 (Audio Capture)
  ↓
S.03 (Streaming)
  ↓
S.04 (Control + EOU)
  ↓
S.05 (Always-On)
```

---

## Tech Stack

- **Language:** Swift 6.0 with strict concurrency
- **Frameworks:** AVFoundation, CoreML, Accelerate
- **ASR Engine:** FluidAudio/Parakeet (Core ML, Apple Neural Engine)
- **Target:** macOS 14.0+ (Sonoma), Apple Silicon (M1+)

---

## Prerequisites

1. **macOS 14.0+** (Sonoma or later)
2. **Xcode 15.0+** with Swift 6 support
3. **Apple Silicon** (M1/M2/M3) recommended for Neural Engine
4. **FluidAudio SDK** (licensed separately)

---

## Getting Started

### 1. Project Setup

```bash
# Create new macOS app project
# Add FluidAudio SDK to your project
# Configure Info.plist for microphone permission:
```

**Info.plist:**
```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone for voice transcription.</string>
```

### 2. Implementation Order

Follow the stories in order:

1. **S.01** - Get Parakeet engine loading and transcribing
2. **S.02** - Capture microphone audio in correct format
3. **S.03** - Wire up streaming with partials/finals
4. **S.04** - Add state management and control API
5. **S.05** - Enable always-on continuous listening

### 3. Testing

Each story includes comprehensive test cases. Run tests after completing each story before moving to the next.

```bash
xcodebuild test -scheme YourApp -destination 'platform=macOS'
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  TranscriptionController                │
│                    (State Machine)                      │
└─────────────────────┬───────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        │             │             │
        ▼             ▼             ▼
┌───────────┐  ┌────────────┐  ┌──────────────┐
│  Audio    │  │ Streaming  │  │   Parakeet   │
│  Capture  │  │  Manager   │  │   Engine     │
└─────┬─────┘  └──────┬─────┘  └──────────────┘
      │               │
      ▼               ▼
┌───────────┐  ┌────────────┐
│   Ring    │  │  Partial   │
│  Buffer   │  │  Differ    │
└───────────┘  └────────────┘
```

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Partial latency | <400ms |
| Final latency | <300ms after pause |
| CPU (active speech) | <30% on M1 |
| CPU (silence) | <5% on M1 |
| Memory (5 min buffer) | ~20MB |
| Transcription RTF | 50-100x real-time |

---

## Key Design Principles

### 1. Swift 6 Strict Concurrency
All code uses `@Sendable`, `@MainActor`, and manual locks where needed. Thread Sanitizer clean.

### 2. Protocol-Based Abstraction
`ASREngine` protocol allows future engine additions without core changes.

### 3. Lock-Free Audio Path
Real-time audio callbacks never block. Ring buffer uses atomic operations.

### 4. Notification-Based Decoupling
Components communicate via NotificationCenter, reducing tight coupling.

### 5. Graceful Degradation
Errors are handled gracefully with recovery paths and clear user feedback.

---

## License

These implementation stories are provided as a reference. Ensure you have appropriate licenses for:
- FluidAudio SDK
- Parakeet models from HuggingFace

---

## Support

For questions about FluidAudio/Parakeet integration, refer to:
- [FluidAudio Documentation](https://docs.fluidaudio.ai)
- [Parakeet Models on HuggingFace](https://huggingface.co/FluidInference)
