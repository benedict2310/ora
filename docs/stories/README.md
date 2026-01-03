# Ora - Architecture & Implementation Stories

> **Note:** This repository follows a strict documentation-driven development process. Every feature must be defined in a story file before implementation begins.

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
| F.10 | [Liquid Glass Overlay Refresh](foundations/F.10-LIQUID-GLASS-OVERLAY-REFRESH.md) | 🚧 To Do |

#### Bug Fixes

| ID | Title | Status |
|:---|:------|:-------|
| BUG.01 | [Model Download Verification](foundations/BUG.01-MODEL-DOWNLOAD-VERIFICATION.md) | ✅ Fixed |

### 🎙 ASR Integration (A)
Speech-to-text pipeline using FluidAudio Parakeet.

| ID | Title | Status |
|:---|:------|:-------|
| A.01 | [Audio Service](asr-integration/A.01-AUDIO-SERVICE.md) | ✅ Complete |
| A.02 | [ASR Service](asr-integration/A.02-ASR-SERVICE.md) | ✅ Complete |
| A.03 | [Transcript Stream](asr-integration/A.03-TRANSCRIPT-STREAM.md) | ✅ Complete |
| A.04 | [Hotkey Wiring](asr-integration/A.04-HOTKEY-WIRING.md) | ✅ Complete |

### 🧠 LLM Integration (L)
Local inference using MLX Swift and Qwen 2.5.

| ID | Title | Status |
|:---|:------|:-------|
| L.01 | [LLM Runtime](llm-integration/L.01-LLM-RUNTIME.md) | ✅ Complete |
| L.02 | [Structured Output](llm-integration/L.02-STRUCTURED-OUTPUT.md) | ✅ Complete |
| L.03 | [Conversation Manager](llm-integration/L.03-CONVERSATION-MANAGER.md) | ✅ Complete |
| L.04 | [System Prompt](llm-integration/L.04-SYSTEM-PROMPT.md) | ✅ Complete |
| L.05 | [Additional LLM Models](llm-integration/L.05-ADDITIONAL-LLM-MODELS.md) | 🚧 To Do |

### 🗣 TTS Integration (T)
Text-to-speech using Kokoro MLX.

| ID | Title | Status |
|:---|:------|:-------|
| T.01 | [TTS Service](tts-integration/T.01-TTS-SERVICE.md) | ⚠️ Partial (Fallback) |
| T.02 | [Audio Playback](tts-integration/T.02-AUDIO-PLAYBACK.md) | 🚧 To Do |
| T.03 | [Sentence Chunker](tts-integration/T.03-SENTENCE-CHUNKER.md) | 🚧 To Do |

### 🛠 Tools (X)
Agentic tools for system integration.

| ID | Title | Status |
|:---|:------|:-------|
| X.01 | [Tool Protocol](tools/X.01-TOOL-PROTOCOL.md) | ✅ Complete |
| X.02 | [Calendar Tools](tools/X.02-CALENDAR-TOOLS.md) | 🚧 To Do |
| X.03 | [Reminders Tools](tools/X.03-REMINDERS-TOOLS.md) | 🚧 To Do |
| X.04 | [Contacts Tools](tools/X.04-CONTACTS-TOOLS.md) | 🚧 To Do |
| X.05 | [System Tools](tools/X.05-SYSTEM-TOOLS.md) | 🚧 To Do |

### 🎼 Orchestration (O)
Connecting the loop: Audio → ASR → LLM → Tools → TTS.

| ID | Title | Status |
|:---|:------|:-------|
| O.01 | [ASR-LLM Pipeline](orchestration/O.01-ASR-LLM-PIPELINE.md) | ✅ Complete |
| O.02 | [Agent Loop](orchestration/O.02-AGENT-LOOP.md) | 🚧 To Do |
| O.03 | [Conversation Orchestrator](orchestration/O.03-CONVERSATION-ORCHESTRATOR.md) | 🚧 To Do |
| O.04 | [Confirmation Flow](orchestration/O.04-CONFIRMATION-FLOW.md) | 🚧 To Do |
| O.05 | [Improved Hotkey Flow](orchestration/O.05-IMPROVED-HOTKEY-FLOW.md) | ✅ Complete |

---

## Dependency Graph

```
                           ┌─────────────────────────────────────┐
                           │         FOUNDATIONS (F)              │
                           │  F.00 → F.01 → F.02 → F.03 → F.04   │
                           │         F.05, F.06, F.07, F.08, F.09 │
                           └──────────────────┬──────────────────┘
                                              │ ✅ All Complete
                    ┌─────────────────────────┼─────────────────────────┐
                    │                         │                         │
                    ▼                         ▼                         ▼
         ┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
         │   ASR (A)        │      │   LLM (L)        │      │   TTS (T)        │
         │ A.01 → A.02 →    │      │ L.01 → L.02 →    │      │ T.01 → T.02 →    │
         │ A.03 → A.04      │      │ L.03, L.04       │      │ T.03             │
         │ ✅ All Complete  │      │ ✅ All Complete  │      │ 🚧 To Do         │
         └────────┬─────────┘      └────────┬─────────┘      └────────┬─────────┘
                  │                         │                         │
                  │                         │                         │
                  └────────────┬────────────┘                         │
                               │                                      │
                               ▼                                      │
                  ┌────────────────────────┐                          │
                  │  O.01 ASR-LLM Pipeline │                          │
                  │  ✅ Complete           │                          │
                  └───────────┬────────────┘                          │
                              │                                       │
         ┌────────────────────┤                                       │
         │                    │                                       │
         ▼                    ▼                                       │
┌─────────────────┐  ┌─────────────────┐                              │
│  TOOLS (X)      │  │  O.02 Agent     │                              │
│  X.01 ✅        │  │  Loop           │                              │
│  X.02-X.05      │  │  🚧 To Do       │                              │
│  🚧 To Do       │  └────────┬────────┘                              │
└────────┬────────┘           │                                       │
         │                    │                                       │
         └─────────┬──────────┘                                       │
                   │                                                  │
                   ▼                                                  │
         ┌─────────────────────────────────────────────────┐          │
         │  O.03 Conversation Orchestrator                 │◄─────────┘
         │  (Full pipeline: ASR → LLM → Tools → TTS)       │
         │  🚧 To Do                                       │
         └────────────────────────┬────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │  O.04 Confirmation Flow │
                    │  🚧 To Do               │
                    └─────────────────────────┘
```

---

## Implementation Order

### ✅ Phase 1: Foundations (Complete)
All foundation stories (F.00-F.09) are complete. This includes app shell, permissions, model management, hotkey, overlay, and persistence.

### ✅ Phase 2: Core Services (Complete)
- **ASR (A.01-A.04):** Audio capture, Parakeet ASR, transcription streaming, hotkey wiring
- **LLM (L.01-L.04):** MLX runtime, structured output, conversation manager, system prompt

### ✅ Phase 3: Basic Pipeline (Complete)
- **O.01:** ASR-LLM Pipeline - Voice input wired to LLM response
- **X.01:** Tool Protocol - Foundation for agentic tools

### 🚧 Phase 4: Tools & Agent Loop (Current)

**Recommended next:** Start with **O.02 - Agent Loop**. This enables the LLM to parse tool calls, execute them via ToolHost, and continue reasoning until done. Once O.02 works, implement the actual tools (X.02-X.05).

| Priority | Story | Description |
|:---------|:------|:------------|
| **P0** | **O.02** | **Agent Loop** - Multi-step reasoning with tool calls ← **Start here** |
| P1 | X.02 | Calendar Tools - Query, create, delete events |
| P1 | X.03 | Reminders Tools - Create, list reminders |
| P1 | X.04 | Contacts Tools - Search contacts |
| P1 | X.05 | System Tools - Open apps, URLs |

**Alternative:** If you want voice output first, skip to **T.01 - TTS Service**.

### 🚧 Phase 5: TTS Integration
| Priority | Story | Description |
|:---------|:------|:------------|
| P1 | T.01 | TTS Service - Kokoro MLX integration |
| P1 | T.02 | Audio Playback - Output audio pipeline |
| P2 | T.03 | Sentence Chunker - Stream audio as sentences complete |

### 🚧 Phase 6: Full Orchestration
| Priority | Story | Description |
|:---------|:------|:------------|
| P0 | O.03 | Conversation Orchestrator - Full pipeline coordination |
| P1 | O.04 | Confirmation Flow - Tool mutation confirmation UI |

### 📋 Optional/Deferred
| Priority | Story | Description |
|:---------|:------|:------------|
| P2 | L.05 | Additional LLM Models - More model options |

---

## Workflow

1. **Pick a Story:** Select the next prioritized story from the list.
2. **Review:** Read the story file carefully.
3. **Implement:** Write code, tests, and documentation.
4. **Verify:** Ensure all Acceptance Criteria (AC) are met.
5. **Update:** Mark the story as "✅ Complete" in this README.
