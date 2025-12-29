# Ora - Implementation Stories

> **Central index of all implementation stories for building Ora, a privacy-first macOS voice assistant.**

---

## Quick Links

| Document | Description |
|:---------|:------------|
| [PRD.md](PRD.md) | Product Requirements Document |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System Architecture & Design |
| [Liquid Glass UI Reference](../references/liquid-glass-ui.md) | iOS/macOS 26 Liquid Glass design guide |

---

## Epic Overview

| Epic | Stories | Description | Status |
|:-----|:--------|:------------|:-------|
| [Foundations](foundations/) | F.00 - F.08 | App shell, permissions, model management, UI infrastructure | ✅ 9 implemented |
| [Parakeet Starter](parakeet-starter/) | S.01 - S.05 | ASR engine integration (FluidAudio Parakeet) | 📝 2 ready for implementation · 📝 2 draft · ⏳ 1 not started |
| [ASR Integration](asr-integration/) | A.01 - A.03 | Connect Parakeet to Ora's pipeline | ⏳ 3 not started |
| [LLM Integration](llm-integration/) | L.01 - L.04 | MLX Swift, Qwen 2.5, structured output | ⏳ 4 not started |
| [TTS Integration](tts-integration/) | T.01 - T.03 | Kokoro MLX text-to-speech | ⏳ 3 not started |
| [Tools](tools/) | X.01 - X.05 | Calendar, Reminders, Contacts, System tools | ⏳ 5 not started |
| [Orchestration](orchestration/) | O.01 - O.03 | Agent loop, conversation flow, confirmation | ⏳ 3 not started |
| [Reliability](reliability/) | E.01 | Error recovery, fallbacks, graceful degradation | ⏳ 1 not started |

**Legend:** ✅ Implemented | 🟡 In Review | 🟡 Ready for Code Review | 📝 Ready for Implementation | 📝 Draft | ⏳ Not Started

Status labels in the tables below reflect the `**Status:**` line from each story header.

---

## Implementation Order

### Phase 1: Foundation (Week 1-2)

Build the app shell and infrastructure before any AI features.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 1 | F.01 | [App Shell & Menu Bar](foundations/F.01-APP-SHELL-MENUBAR.md) | 1d | ✅ | ✅ Implemented |
| 2 | F.08 | [Persistence Layer](foundations/F.08-PERSISTENCE-LAYER.md) | 1d | ✅ | ✅ Implemented |
| 3 | F.02 | [Permissions Manager](foundations/F.02-PERMISSIONS-MANAGER.md) | 1d | ✅ | ✅ Implemented |
| 4 | F.03 | [Model Manager](foundations/F.03-MODEL-MANAGER.md) | 2d | ✅ | ✅ Implemented |
| 5 | F.05 | [Global Hotkey](foundations/F.05-GLOBAL-HOTKEY.md) | 1d | ✅ | ✅ Implemented |
| 6 | F.07 | [Overlay Window](foundations/F.07-OVERLAY-WINDOW.md) | 2d | ✅ | ✅ Implemented |
| 7 | F.04 | [First-Run Setup](foundations/F.04-FIRST-RUN-SETUP.md) | 2-3d | ✅ | ✅ Implemented |
| 8 | F.06 | [Preferences Window](foundations/F.06-PREFERENCES-WINDOW.md) | 2d | ✅ | ✅ Implemented |
| 9 | F.00 | [Design Assets](foundations/F.00-DESIGN-ASSETS.md) | 1d | | ✅ Implemented |

**Milestone:** App launches, shows menu bar, hotkey works, overlay appears.

---

### Phase 2: ASR Pipeline (Week 2-3)

Integrate FluidAudio Parakeet for speech-to-text.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 10 | S.01 | [Core Engine Integration](parakeet-starter/S.01-CORE-ENGINE-INTEGRATION.md) | 2d | ✅ | ⏳ Not Started |
| 11 | S.02 | [Audio Capture Pipeline](parakeet-starter/S.02-AUDIO-CAPTURE-PIPELINE.md) | 2d | ✅ | 📝 Ready for Implementation |
| 12 | S.03 | [Real-Time Streaming](parakeet-starter/S.03-REALTIME-STREAMING-TRANSCRIPTION.md) | 2d | ✅ | 📝 Draft |
| 13 | A.01 | [Audio Service](asr-integration/A.01-AUDIO-SERVICE.md) | 1d | ✅ | ⏳ Not Started |
| 14 | A.02 | [ASR Service](asr-integration/A.02-ASR-SERVICE.md) | 1d | ✅ | ⏳ Not Started |
| 15 | A.03 | [Transcript Stream](asr-integration/A.03-TRANSCRIPT-STREAM.md) | 1d | ✅ | ⏳ Not Started |

**Milestone:** PTT captures audio, transcription streams to overlay.

---

### Phase 3: LLM Integration (Week 3-4)

Add local language model reasoning with MLX Swift.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 16 | L.01 | [LLM Runtime](llm-integration/L.01-LLM-RUNTIME.md) | 2d | ✅ | ⏳ Not Started |
| 17 | L.02 | [Structured Output](llm-integration/L.02-STRUCTURED-OUTPUT.md) | 2d | ✅ | ⏳ Not Started |
| 18 | L.03 | [Conversation Manager](llm-integration/L.03-CONVERSATION-MANAGER.md) | 1d | ✅ | ⏳ Not Started |
| 19 | L.04 | [System Prompt](llm-integration/L.04-SYSTEM-PROMPT.md) | 1d | ✅ | ⏳ Not Started |

**Milestone:** LLM generates structured responses from transcripts.

---

### Phase 4: Tools (Week 4-5)

Implement agentic tools for real-world actions.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 20 | X.01 | [Tool Protocol](tools/X.01-TOOL-PROTOCOL.md) | 1-2d | ✅ | ⏳ Not Started |
| 21 | X.02 | [Calendar Tools](tools/X.02-CALENDAR-TOOLS.md) | 2d | ✅ | ⏳ Not Started |
| 22 | X.03 | [Reminders Tools](tools/X.03-REMINDERS-TOOLS.md) | 1d | ✅ | ⏳ Not Started |
| 23 | X.04 | [Contacts Tools](tools/X.04-CONTACTS-TOOLS.md) | 1d | | ⏳ Not Started |
| 24 | X.05 | [System Tools](tools/X.05-SYSTEM-TOOLS.md) | 1d | | ⏳ Not Started |

**Milestone:** LLM can query calendar, create reminders, search contacts.

---

### Phase 5: TTS Integration (Week 5)

Add voice output with Kokoro MLX.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 25 | T.01 | [TTS Service](tts-integration/T.01-TTS-SERVICE.md) | 2d | ✅ | ⏳ Not Started |
| 26 | T.02 | [Audio Playback](tts-integration/T.02-AUDIO-PLAYBACK.md) | 1d | ✅ | ⏳ Not Started |
| 27 | T.03 | [Sentence Chunker](tts-integration/T.03-SENTENCE-CHUNKER.md) | 1d | ✅ | ⏳ Not Started |

**Milestone:** Responses are spoken aloud with streaming playback.

---

### Phase 6: Orchestration (Week 5-6)

Wire everything together into a complete assistant.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 28 | O.01 | [Agent Loop](orchestration/O.01-AGENT-LOOP.md) | 2-3d | ✅ | ⏳ Not Started |
| 29 | O.02 | [Conversation Orchestrator](orchestration/O.02-CONVERSATION-ORCHESTRATOR.md) | 2-3d | ✅ | ⏳ Not Started |
| 30 | O.03 | [Confirmation Flow](orchestration/O.03-CONFIRMATION-FLOW.md) | 1-2d | ✅ | ⏳ Not Started |

**Milestone:** Full PTT → ASR → LLM → Tools → TTS pipeline working.

---

### Phase 6b: Reliability (Week 6)

Error handling and graceful degradation.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 31 | E.01 | [Error Recovery & Fallbacks](reliability/E.01-ERROR-RECOVERY.md) | 2-3d | ✅ | ⏳ Not Started |

**Milestone:** Graceful error handling, automatic recovery, fallback modes.

---

### Phase 7: Polish & Enhancements (Week 6+)

v2 enhancements and refinements.

| Order | Story | Title | Effort | Critical Path | Status |
|:-----:|:------|:------|:------:|:-------------:|:-------|
| 32 | S.04 | [Transcription Control](parakeet-starter/S.04-TRANSCRIPTION-CONTROL.md) | 2d | | 📝 Ready for Implementation |
| 33 | S.05 | [Always-On Mode](parakeet-starter/S.05-ALWAYS-ON-CONTINUOUS-LISTENING.md) | 3d | | 📝 Draft |

**Milestone:** VAD-based end-of-utterance, optional always-on mode.

---

## Dependency Graph

```
                                F.01 (App Shell)
                                      │
              ┌───────────────────────┼───────────────────────┐
              │                       │                       │
              ▼                       ▼                       ▼
        F.02 (Perms)            F.08 (Persist)          F.03 (Models)
              │                       │                       │
              ├───────────────────────┼───────────────────────┤
              │                       │                       │
              ▼                       ▼                       ▼
        F.05 (Hotkey)           X.01 (Tools)            L.01 (LLM)
              │                       │                       │
              ▼                       │                       │
        F.07 (Overlay)                │                       │
              │                       ├───────────┬───────────┤
              │                       │           │           │
              │                       ▼           ▼           ▼
              │                 X.02-X.05     L.02-L.04   T.01-T.03
              │                  (Tools)        (LLM)       (TTS)
              │                       │           │           │
              └───────────────────────┼───────────┼───────────┘
                                      │           │
                                      ▼           ▼
                           S.01-S.03 (Parakeet) ──► A.01-A.03 (ASR)
                                                        │
                                                        ▼
                                              O.01-O.03 (Orchestration)
                                                        │
                                                        ▼
                                              E.01 (Error Recovery)
```

---

## Story Count by Epic

| Epic | Total | Critical Path |
|:-----|:-----:|:-------------:|
| Foundations | 9 | 7 |
| Parakeet Starter | 5 | 3 (v1) |
| ASR Integration | 3 | 3 |
| LLM Integration | 4 | 4 |
| TTS Integration | 3 | 3 |
| Tools | 5 | 3 |
| Orchestration | 3 | 3 |
| Reliability | 1 | 1 |
| **Total** | **33** | **27** |

---

## Gaps & Open Topics

### ✅ Addressed Gaps

| Gap | Resolution |
|:----|:-----------|
| **Error Recovery** | Added [E.01 - Error Recovery & Fallbacks](reliability/E.01-ERROR-RECOVERY.md) |
| **Memory Management** | Extended [L.01 - LLM Runtime](llm-integration/L.01-LLM-RUNTIME.md) with memory management section |
| **Audit Log UI** | Extended [F.06 - Preferences](foundations/F.06-PREFERENCES-WINDOW.md) with full audit log viewer |
| **Accessibility** | Added accessibility acceptance criteria to F.07, O.03 |
| **Keyboard Navigation** | Added keyboard navigation acceptance criteria to F.07, O.03 |

### 🟡 Remaining Gaps (Lower Priority)

| Gap | Description | Recommendation |
|:----|:------------|:---------------|
| **Model Selection UI** | Runtime model switching in preferences | Already in F.06 Models tab, verify implementation |

### 🟢 Nice-to-Have (Future)

| Gap | Description | Recommendation |
|:----|:------------|:---------------|
| **Wake Word** | PRD mentions optional wake word for v2 | Future epic after v1 |
| **Multi-turn Memory** | Long-term conversation memory | Future epic |
| **Undo Voice Command** | "Undo that" voice command | Add to O.03 or future |
| **Analytics/Telemetry** | Local usage analytics for debugging | Future story |
| **Cancellation Patterns** | Document unified cancellation approach | Add to ARCHITECTURE.md |

---

## UI Stories - Liquid Glass Design

The following stories contain UI components that **must** reference the [Liquid Glass UI Guide](../references/liquid-glass-ui.md):

| Story | UI Components |
|:------|:--------------|
| F.04 | First-Run Setup window, step navigation |
| F.06 | Preferences window, tab navigation |
| F.07 | Overlay window, status indicator, message bubbles, confirmation dialog |
| O.03 | Confirmation view, countdown timer, action buttons |
| A.03 | Transcript display in overlay |

### Key Liquid Glass Patterns for Ora

```swift
// Overlay window - floating glass panel
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))

// Action buttons - glass button style  
Button("Confirm") { }
    .buttonStyle(.glassProminent)
    .tint(.blue)

// Secondary buttons
Button("Cancel") { }
    .buttonStyle(.glass)

// Status indicator with glass container
GlassEffectContainer {
    HStack {
        StatusIndicator()
        // ...
    }
    .glassEffect()
}

// Morphing transitions for state changes
.glassEffectID("status", in: namespace)
```

---

## Testing Strategy

### Per-Story Testing

Each story includes test cases. Run tests after completing each story:

```bash
xcodebuild test -project Ora.xcodeproj -scheme Ora
```

### Integration Testing

After each phase milestone:
1. Run full test suite
2. Manual smoke test of new features
3. Thread Sanitizer run (`Ora-TSan` scheme)

### Performance Testing

After Phase 6 (Orchestration):
- Profile with Instruments
- Measure PTT → first audio latency
- Check memory growth over 30+ minutes

---

## Getting Started

1. **Read** [ARCHITECTURE.md](ARCHITECTURE.md) for system design
2. **Start** with [F.01 - App Shell](foundations/F.01-APP-SHELL-MENUBAR.md)
3. **Follow** the implementation order above
4. **Reference** [Liquid Glass UI](../references/liquid-glass-ui.md) for all UI work
5. **Test** after each story completion

---

## Version History

| Version | Date | Changes |
|:--------|:-----|:--------|
| 1.0 | 2025-12-27 | Initial story index with all 32 stories |
