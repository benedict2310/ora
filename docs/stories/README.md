# Ora - Architecture & Implementation Stories

> **Note:** This repository follows a strict documentation-driven development process. Every feature must be defined in a story file before implementation begins.

## Current Status

**Voice assistant MVP is functional!** You can:
- Press hotkey → speak → get LLM response → hear TTS playback
- Multi-turn conversations with context preserved

**What's working:**
- ✅ Hotkey activation (Option+Space)
- ✅ Speech-to-text (Parakeet ASR)
- ✅ LLM responses (Qwen 3 via MLX)
- ✅ Text-to-speech (Kokoro TTS)
- ✅ Overlay UI with conversation display
- ✅ Auto-listen for follow-up turns
- ✅ Conversation Mode (silence detection)
- ✅ Calendar tools (query, create, edit, delete events)
- ✅ Multi-step agentic flows (query → delete with confirmation)

**What's next:**
- 🚧 Improve Ora.app test coverage to 85%+ (M.01, now 72.8%)
- 🚧 Fix setup wizard UX (F.11)
- 🚧 Build confirmation flow polish (O.04)
- 🚧 Implement Reminders, Contacts, System tools (X.03-X.05)

**Current priority:** M.01 Test Coverage Improvements (raise Ora.app to 85%+; next tranche: ParakeetModelDownloader verification + remaining setup/download gating paths).

**Next actions (M.01):**
- Exercise `Ora/ASR/ParakeetModelDownloader.swift` verification/error paths via helper extraction.
- Expand setup/download gating coverage in `Ora/Setup/SetupCoordinator.swift`.
- Re-run coverage and update `docs/stories/maintenance/M.01-TEST-COVERAGE-IMPROVEMENTS.md`.

---

## Recent Maintenance

- 2026-01-05: Removed stale local branches (`feat/f10-liquid-glass-overlay`, `feat/O.02-agent-loop`) after audit. See `docs/reports/branch-merge-status-2026-01-05.md`.

## Epics

### 🏗 Foundations (F)
Core application structure, UI, and state management.

| ID | Title | Status |
|:---|:------|:-------|
| F.00 | [Design Assets](foundations/F.00-DESIGN-ASSETS.md) | ✅ Complete |
| F.01 | [App Shell & Menu Bar](foundations/F.01-APP-SHELL-MENUBAR.md) | ✅ Complete |
| F.02 | [Permissions Manager](foundations/F.02-PERMISSIONS-MANAGER.md) | ✅ Complete |
| F.03 | [Model Manager](foundations/F.03-MODEL-MANAGER.md) | ✅ Complete |
| F.04 | [First Run Setup](foundations/F.04-FIRST-RUN-SETUP.md) | ✅ Complete |
| F.05 | [Global Hotkey](foundations/F.05-GLOBAL-HOTKEY.md) | ✅ Complete |
| F.06 | [Preferences Window](foundations/F.06-PREFERENCES-WINDOW.md) | ✅ Complete |
| F.07 | [Overlay Window](foundations/F.07-OVERLAY-WINDOW.md) | ✅ Complete |
| F.08 | [Persistence Layer](foundations/F.08-PERSISTENCE-LAYER.md) | ✅ Complete |
| F.09 | [Model Download Implementation](foundations/F.09-MODEL-DOWNLOAD-IMPLEMENTATION.md) | ✅ Complete |
| F.10 | [Liquid Glass Overlay Refresh](foundations/F.10-LIQUID-GLASS-OVERLAY-REFRESH.md) | 📋 Deferred |
| F.11 | [Setup Wizard Polish](foundations/F.11-SETUP-WIZARD-POLISH.md) | 🚧 To Do |
| F.13 | [Sparkle Auto-Updates](foundations/F.13-SPARKLE-AUTO-UPDATES.md) | 🚧 To Do |

#### Bug Fixes

| ID | Title | Status |
|:---|:------|:-------|
| BUG.01 | [Model Download Verification](foundations/BUG.01-MODEL-DOWNLOAD-VERIFICATION.md) | ✅ Fixed |

### 🎨 UX (UX)
User experience improvements for overlay clarity and interaction.

| ID | Title | Status |
|:---|:------|:-------|
| UX.00 | [Overlay Bubble Spacing](ux/UX.00-OVERLAY-BUBBLE-SPACING.md) | 🚧 To Do |
| UX.01 | [Agent Transparency Status](ux/UX.01-AGENT-TRANSPARENCY-STATUS.md) | ✅ Complete |
| UX.02 | [Overlay Bubble Copy Action](ux/UX.02-OVERLAY-BUBBLE-COPY.md) | ✅ Complete |
| UX.03 | [Overlay Visual Polish](ux/UX.03-OVERLAY-VISUAL-POLISH.md) | 🚧 To Do |

### 🎙 ASR Integration (A)
Speech-to-text pipeline using FluidAudio Parakeet.

| ID | Title | Status |
|:---|:------|:-------|
| A.01 | [Audio Service](asr-integration/A.01-AUDIO-SERVICE.md) | ✅ Complete |
| A.02 | [ASR Service](asr-integration/A.02-ASR-SERVICE.md) | ✅ Complete |
| A.03 | [Transcript Stream](asr-integration/A.03-TRANSCRIPT-STREAM.md) | ✅ Complete |
| A.04 | [Hotkey Wiring](asr-integration/A.04-HOTKEY-WIRING.md) | ✅ Complete |

### 🧠 LLM Integration (L)
Local inference using MLX Swift.

| ID | Title | Status |
|:---|:------|:-------|
| L.01 | [LLM Runtime](llm-integration/L.01-LLM-RUNTIME.md) | ✅ Complete |
| L.02 | [Structured Output](llm-integration/L.02-STRUCTURED-OUTPUT.md) | ✅ Complete |
| L.03 | [Conversation Manager](llm-integration/L.03-CONVERSATION-MANAGER.md) | ✅ Complete |
| L.04 | [System Prompt](llm-integration/L.04-SYSTEM-PROMPT.md) | ✅ Complete |
| L.05 | [Additional LLM Models](llm-integration/L.05-ADDITIONAL-LLM-MODELS.md) | 📋 Deferred |
| L.06 | [Qwen 3 Upgrade](llm-integration/L.06-QWEN3-UPGRADE.md) | ✅ Complete |

### 🗣 TTS Integration (T)
Text-to-speech using Kokoro MLX.

| ID | Title | Status |
|:---|:------|:-------|
| T.01 | [TTS Service](tts-integration/T.01-TTS-SERVICE.md) | ✅ Complete |
| T.02 | [Audio Playback](tts-integration/T.02-AUDIO-PLAYBACK.md) | ✅ Complete |
| T.03 | [Sentence Chunker](tts-integration/T.03-SENTENCE-CHUNKER.md) | ✅ Complete |

### 🛠 Tools (X)
Agentic tools for system integration.

| ID | Title | Status |
|:---|:------|:-------|
| X.01 | [Tool Protocol](tools/X.01-TOOL-PROTOCOL.md) | ✅ Complete |
| X.02 | [Calendar Tools](tools/X.02-CALENDAR-TOOLS.md) | ✅ Complete |
| X.03 | [Reminders Tools](tools/X.03-REMINDERS-TOOLS.md) | 🚧 To Do |
| X.04 | [Contacts Tools](tools/X.04-CONTACTS-TOOLS.md) | 🚧 To Do |
| X.05 | [System Tools](tools/X.05-SYSTEM-TOOLS.md) | 🚧 To Do |
| X.07A | [Mail: Compose](tools/X.07A-MAIL-COMPOSE.md) | 🚧 To Do |

### 🧹 Maintenance (M)
Quality, coverage, and repository hygiene.

| ID | Title | Status |
|:---|:------|:-------|
| M.01 | [Test Coverage Improvements](maintenance/M.01-TEST-COVERAGE-IMPROVEMENTS.md) | 🚧 In Progress |
| M.02 | [Unified Model Status Tracking](maintenance/M.02-UNIFIED-MODEL-STATUS-TRACKING.md) | ✅ Complete |
| M.03 | [Response Triggering Improvements](maintenance/M.03-STT-QUALITY-IMPROVEMENTS.md) | ✅ Complete |
| M.04 | [Voice Processing](maintenance/M.04-VOICE-PROCESSING.md) | 🚧 To Do |

### 🎼 Orchestration (O)
Connecting the loop: Audio → ASR → LLM → Tools → TTS.

| ID | Title | Status |
|:---|:------|:-------|
| O.01 | [ASR-LLM Pipeline](orchestration/O.01-ASR-LLM-PIPELINE.md) | ✅ Complete |
| O.02 | [Agent Loop](orchestration/O.02-AGENT-LOOP.md) | ✅ Complete |
| O.03 | [Conversation Orchestrator](orchestration/O.03-CONVERSATION-ORCHESTRATOR.md) | ✅ Complete |
| O.04 | [Confirmation Flow](orchestration/O.04-CONFIRMATION-FLOW.md) | 🚧 To Do |
| O.05 | [Improved Hotkey Flow](orchestration/O.05-IMPROVED-HOTKEY-FLOW.md) | ✅ Complete |
| O.06 | [Agent Loop Integration](orchestration/O.06-AGENT-LOOP-INTEGRATION.md) | ✅ Complete |
| O.07 | [Conversation Mode](orchestration/O.07-CONVERSATION-MODE.md) | ✅ Complete |

### 📚 Skills (S)
Optional orchestration playbooks that layer on top of native tools.

| ID | Title | Status |
|:---|:------|:-------|
| S.01 | [Skills Runtime](skills/S.01-SKILLS-RUNTIME.md) | 📋 Future |
| S.02 | [Skills Evaluation](skills/S.02-SKILLS-EVALUATION.md) | 📋 Future |
| S.03 | [Skill Scripts](skills/S.03-SKILL-SCRIPTS.md) | 📋 Future |
| S.04 | [Skills Marketplace](skills/S.04-SKILLS-MARKETPLACE.md) | 📋 Future |
| S.05 | [Embedding Retrieval](skills/S.05-EMBEDDING-RETRIEVAL.md) | 📋 Future |

---

## Implementation Order

### ✅ Phase 1: Foundations (Complete)
All foundation stories (F.00-F.09) are complete. This includes app shell, permissions, model management, hotkey, overlay, and persistence.

### ✅ Phase 2: Core Services (Complete)
- **ASR (A.01-A.04):** Audio capture, Parakeet ASR, transcription streaming, hotkey wiring
- **LLM (L.01-L.04):** MLX runtime, structured output, conversation manager, system prompt
- **TTS (T.01-T.02):** Kokoro TTS, audio playback with jitter buffer

### ✅ Phase 3: Basic Pipeline (Complete)
- **O.01:** ASR-LLM Pipeline - Voice input wired to LLM response
- **O.02:** Agent Loop - Core reasoning with tool execution (infrastructure only)
- **O.03:** Conversation Orchestrator - Full pipeline with TTS integration
- **O.05:** Improved Hotkey Flow - Tap-to-start, Enter-to-submit
- **X.01:** Tool Protocol - Foundation for agentic tools
- **X.02:** Calendar Tools - Query, create, delete events (implemented but not wired)

### ✅ Phase 4: Working Tools (Complete)

AgentLoop is wired into the pipeline and calendar tools work end-to-end.

| Priority | Story | Description | Status |
|:---------|:------|:------------|:-------|
| ✅ | O.06 | Agent Loop Integration - Wire AgentLoop into pipeline so tools work | ✅ Complete |
| P1 | O.04 | Confirmation Flow - UI polish for confirming tool mutations | 🚧 To Do |

### 🚧 Phase 4.5: Quality & Maintenance

| Priority | Story | Description | Status |
|:---------|:------|:------------|:-------|
| **P0** | **M.01** | **Test Coverage Improvements** - Raise Ora.app coverage to 85%+ | 🚧 In Progress |

### 🚧 Phase 5: Model & UX Improvements

| Priority | Story | Description | Status |
|:---------|:------|:------------|:-------|
| ✅ | **L.06** | **Qwen 3 Upgrade** - Replace Qwen 2.5 with Qwen 3 | ✅ Complete |
| P1 | F.11 | Setup Wizard Polish - Fix broken-feeling download UI | 🚧 To Do |
| ✅ | O.07 | Conversation Mode - Silence detection, auto-submit | ✅ Complete |

### 🚧 Phase 6: Additional Tools

| Priority | Story | Description | Status |
|:---------|:------|:------------|:-------|
| P1 | X.03 | Reminders Tools - Create, list reminders | 🚧 To Do |
| P1 | X.04 | Contacts Tools - Search contacts | 🚧 To Do |
| P1 | X.05 | System Tools - Open apps, URLs | 🚧 To Do |

### 📋 Deferred / Future

| Priority | Story | Description | Reason |
|:---------|:------|:------------|:-------|
| P2 | F.10 | Liquid Glass Overlay Refresh | Nice-to-have visual polish |
| P2 | L.05 | Additional LLM Models | Superseded by L.06 for now |
| P2 | T.03 | Sentence Chunker | Optimization - batch TTS works fine |
| P3 | S.* | Skills Epic | Future capability, not MVP |

---

## Dependency Graph

```
                    ┌────────────────────────────────────────┐
                    │           FOUNDATIONS (F)               │
                    │     F.00-F.09 ✅ All Complete           │
                    └──────────────────┬─────────────────────┘
                                       │
          ┌────────────────────────────┼────────────────────────────┐
          │                            │                            │
          ▼                            ▼                            ▼
┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐
│    ASR (A)       │        │    LLM (L)       │        │    TTS (T)       │
│  ✅ Complete     │        │  ✅ Complete     │        │  ✅ Complete     │
└────────┬─────────┘        └────────┬─────────┘        └────────┬─────────┘
         │                           │                           │
         └───────────────┬───────────┘                           │
                         │                                       │
                         ▼                                       │
          ┌──────────────────────────┐                           │
          │  O.01 ASR-LLM Pipeline   │                           │
          │  ✅ Complete             │                           │
          └────────────┬─────────────┘                           │
                       │                                         │
    ┌──────────────────┼──────────────────┐                      │
    │                  │                  │                      │
    ▼                  ▼                  ▼                      │
┌────────────┐  ┌────────────┐   ┌────────────────┐              │
│ X.01 Tool  │  │ O.02 Agent │   │ O.05 Hotkey    │              │
│ Protocol ✅│  │ Loop ✅    │   │ Flow ✅        │              │
└─────┬──────┘  └─────┬──────┘   └────────────────┘              │
      │               │                                          │
      ▼               │                                          │
┌────────────┐        │                                          │
│ X.02       │        │                                          │
│ Calendar ✅│        │                                          │
└─────┬──────┘        │                                          │
      │               │                                          │
      └───────┬───────┘                                          │
              │                                                  │
              ▼                                                  │
   ┌─────────────────────────────────────────────────┐           │
   │  O.03 Conversation Orchestrator ✅              │◄──────────┘
   │  (Full pipeline: ASR → LLM → TTS)               │
   └────────────────────┬────────────────────────────┘
                        │
         ┌──────────────┴──────────────┐
         │                             │
         ▼                             ▼
┌─────────────────────┐     ┌─────────────────────┐
│  O.06 Agent Loop    │     │  O.07 Conversation  │
│  Integration ✅     │     │  Mode ✅            │
└─────────┬───────────┘     └─────────────────────┘
          │
          ▼
┌─────────────────────┐
│  O.04 Confirmation  │
│  Flow 🚧            │
└─────────────────────┘
```

---

## Quick Reference

### What Works Now
```
Hotkey (⌥Space) → Listening → ASR → LLM → Response → TTS → Audio
                      ↓
              (Enter or silence to submit)
```

### What O.06 Adds
```
Hotkey → Listening → ASR → AgentLoop → Tool Execution → Response → TTS
                              ↓
                    (Calendar queries, event creation, etc.)
```

---

## Workflow

1. **Pick a Story:** Select from "Current Priority" section above
2. **Review:** Read the story file carefully
3. **Implement:** Write code, tests, and documentation
4. **Verify:** Ensure all Acceptance Criteria (AC) are met
5. **Update:** Mark the story as "✅ Complete" in this README
