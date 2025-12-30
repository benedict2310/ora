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
| F.09 | [Model Download Implementation](foundations/F.09-MODEL-DOWNLOAD-IMPLEMENTATION.md) | 🚧 To Do |

### 🎙 ASR Integration (A)
Speech-to-text pipeline using FluidAudio Parakeet.

| ID | Title | Status |
|:---|:------|:-------|
| A.01 | [Audio Service](asr-integration/A.01-AUDIO-SERVICE.md) | ✅ Complete |
| A.02 | [ASR Service](asr-integration/A.02-ASR-SERVICE.md) | ✅ Complete |
| A.03 | [Transcript Stream](asr-integration/A.03-TRANSCRIPT-STREAM.md) | ✅ Complete |
| A.04 | [Hotkey Wiring](asr-integration/A.04-HOTKEY-WIRING.md) | 🚧 To Do |

### 🧠 LLM Integration (L)
Local inference using MLX Swift and Qwen 2.5.

| ID | Title | Status |
|:---|:------|:-------|
| L.01 | [LLM Runtime](llm-integration/L.01-LLM-RUNTIME.md) | 🚧 To Do |
| L.02 | [Structured Output](llm-integration/L.02-STRUCTURED-OUTPUT.md) | 🚧 To Do |
| L.03 | [Conversation Manager](llm-integration/L.03-CONVERSATION-MANAGER.md) | 🚧 To Do |
| L.04 | [System Prompt](llm-integration/L.04-SYSTEM-PROMPT.md) | 🚧 To Do |

### 🗣 TTS Integration (T)
Text-to-speech using Kokoro MLX.

| ID | Title | Status |
|:---|:------|:-------|
| T.01 | [TTS Service](tts-integration/T.01-TTS-SERVICE.md) | 🚧 To Do |
| T.02 | [Audio Playback](tts-integration/T.02-AUDIO-PLAYBACK.md) | 🚧 To Do |
| T.03 | [Sentence Chunker](tts-integration/T.03-SENTENCE-CHUNKER.md) | 🚧 To Do |

### 🛠 Tools (X)
Agentic tools for system integration.

| ID | Title | Status |
|:---|:------|:-------|
| X.01 | [Tool Protocol](tools/X.01-TOOL-PROTOCOL.md) | 🚧 To Do |
| X.02 | [Calendar Tools](tools/X.02-CALENDAR-TOOLS.md) | 🚧 To Do |
| X.03 | [Reminders Tools](tools/X.03-REMINDERS-TOOLS.md) | 🚧 To Do |
| X.04 | [Contacts Tools](tools/X.04-CONTACTS-TOOLS.md) | 🚧 To Do |
| X.05 | [System Tools](tools/X.05-SYSTEM-TOOLS.md) | 🚧 To Do |

### 🎼 Orchestration (O)
Connecting the loop: Audio → ASR → LLM → Tools → TTS.

| ID | Title | Status |
|:---|:------|:-------|
| O.01 | [Assistant Controller](orchestration/O.01-ASSISTANT-CONTROLLER.md) | 🚧 To Do |
| O.02 | [Agent Loop](orchestration/O.02-AGENT-LOOP.md) | 🚧 To Do |
| O.03 | [Audit Logging](orchestration/O.03-AUDIT-LOGGING.md) | 🚧 To Do |

---

## Workflow

1. **Pick a Story:** Select the next prioritized story from the list.
2. **Review:** Read the story file carefully.
3. **Implement:** Write code, tests, and documentation.
4. **Verify:** Ensure all Acceptance Criteria (AC) are met.
5. **Update:** Mark the story as "✅ Complete" in this README.
