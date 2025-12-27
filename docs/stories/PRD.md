# Ora - Product Requirements Document

> **Version:** 1.1
> **Last Updated:** 2025-12-27
> **Minimum macOS:** 26 (Tahoe)

---

## Executive Summary

**Ora** is a privacy-first macOS voice assistant that runs fully on-device using Apple Silicon acceleration. Unlike cloud-based assistants, Ora processes all voice recognition, reasoning, and speech synthesis locally, ensuring user data never leaves the device.

**Primary Differentiator:** Fast, reliable, auditable actions (Calendar/Reminders/Contacts first), minimal cloud dependency, and a UI that makes the assistant feel predictable and safe.

---

## Target Users

| Persona | Description | Key Needs |
|:--------|:------------|:----------|
| **Power Users** | Professionals who want a fast assistant that executes real tasks | Calendar management, task creation, quick contact lookup |
| **Privacy-Conscious Users** | Users who prefer on-device inference | No cloud calls, local processing, data stays on device |
| **Accessibility Users** | Users who benefit from voice-first workflows | Reliable voice input, clear audio feedback, keyboard alternatives |

---

## Core Value Proposition

1. **Privacy by Default:** All processing runs locally; no data leaves your device
2. **Reliable Actions:** Focus on doing a few things exceptionally well (Calendar, Reminders, Contacts)
3. **Transparent & Auditable:** Every action logged with what changed, when, and why
4. **Fast Response:** Optimized pipeline for sub-second voice-to-action latency

---

## System Overview

### High-Level Architecture

```
Voice Input → ASR (Parakeet) → LLM (Local) → Tools/Actions → TTS → Voice Output
                   ↓               ↓              ↓
                   └───────────────┴──────────────┴─────→ UI Overlay
```

### Technology Stack

| Component | Technology | Purpose |
|:----------|:-----------|:--------|
| Language | Swift 6.0 (strict concurrency) | Native macOS performance |
| UI Framework | AppKit + SwiftUI | Native menu bar & overlay |
| Audio | AVFoundation | Microphone capture & playback |
| ASR | FluidAudio Parakeet | Speech-to-text (streaming) |
| LLM Runtime | MLX Swift | On-device inference |
| LLM Model | Qwen 2.5 (7B primary, 3B fallback) | Reasoning & tool calling |
| TTS | Kokoro MLX (AVSpeech fallback) | Text-to-speech |
| Persistence | SwiftData | Sessions, audit logs, preferences |
| System Integration | EventKit, Contacts | Calendar, Reminders, Contacts access |

### System Requirements

| Requirement | Minimum | Recommended | Best |
|:------------|:--------|:------------|:-----|
| macOS Version | 26 (Tahoe) | 26 (Tahoe) | 26 (Tahoe) |
| Chip | Apple Silicon (M1+) | Apple Silicon (M1 Pro+) | Apple Silicon (M2 Pro+) |
| Unified Memory | 8 GB | 16 GB | 32 GB |
| Storage | 10 GB free | 15 GB free | 20 GB free |

**RAM Impact on Experience:**
- **8 GB**: Uses smaller 3B model, limited context window
- **16 GB**: Full 7B model, recommended for best experience
- **32 GB**: Extended context, faster inference, headroom for other apps

---

## v1 Features & Use Cases

### Calendar Integration

| Use Case | Example Command |
|:---------|:----------------|
| Schedule event | "Schedule a 30-min meeting with Maddie next week" |
| View schedule | "What's my day look like tomorrow?" |
| Find availability | "Find a 45-min slot this afternoon" |

### Reminders Integration

| Use Case | Example Command |
|:---------|:----------------|
| Create reminder | "Remind me to submit expenses on Monday" |
| List reminders | "What are my reminders for this week?" |

### Contacts Integration

| Use Case | Example Command |
|:---------|:----------------|
| Lookup contact | "What's Roland's phone number?" |
| Search contacts | "Find Sarah's email address" |

### System Actions

| Use Case | Example Command |
|:---------|:----------------|
| Launch app | "Open Spotify" |
| Web search | "Search the web for..." (opens browser) |

### Settings & Preferences

| Feature | Description |
|:--------|:------------|
| **Model Management** | Download, delete, and select primary LLM model |
| **Model Transparency** | View all models (LLM, ASR, TTS) with size and status |
| **Model Updates** | Notification when updates available; manage in Settings |
| **Hotkey Customization** | Change activation hotkey (`⌥Space` default) |
| **Default Calendar** | Select which calendar to use for new events |
| **Voice Output Toggle** | Enable/disable TTS (Private Mode) |
| **Audit Log Access** | View and clear action history |

### Model Update Flow

Models are updated through app updates, not separately:
1. **Daily app update check** - Ora checks for new versions daily
2. **System notification** - "Ora: Update available (v1.2.0)" with changelog summary
3. **Click notification** → Opens App Store or download page
4. **New models included** - App updates may include new/improved models
5. **Old models retained** - Existing models work until user updates app

### First-Run Experience

On first launch, display a **modal window** that guides the user through setup. The app is not usable until setup is complete.

**Step 1: Welcome**
- Brief introduction to Ora
- Display system RAM and recommend optimal configuration
- Inform user about customizable hotkey (`⌥Space` default)

**Step 2: Permissions**
- Request Microphone, Accessibility, Calendar, Reminders, Contacts
- Explain why each permission is needed
- Allow skipping optional permissions (Calendar, Reminders, Contacts)

**Step 3: Model Download (Blocking)**
- Download **all three models in parallel** with individual progress bars:
  - **Parakeet ASR** (~600 MB) - Speech recognition
  - **Qwen 2.5 LLM** (~5 GB for 7B, ~2 GB for 3B) - Reasoning
  - **Kokoro TTS** (~500 MB) - Voice synthesis
- Display total progress and estimated time
- Auto-select 3B model if system has ≤8 GB RAM (inform user)
- **Postpone behavior:** Shows minimal UI with "Resume Setup" button (app stays open but non-functional)
- Resume support for interrupted downloads (persists across app restarts)
- SHA256 verification after download; show error + retry on failure

**Step 4: Ready**
- Confirm activation hotkey (`⌥Space` or custom)
- Quick tutorial: "Hold hotkey to speak, release to send"
- Link to Preferences for customization
- "Get Started" button to dismiss modal

---

## User Experience Principles

### 1. Push-to-Talk First

- **Primary Activation:** Global hotkey (`⌥Space` default, customizable) + menu bar mic button
- **No Always-Listening:** Privacy-first approach; user initiates all interactions
- **Clear Feedback:** Visual indicator when listening
- **Hotkey Customization:** Users can change the activation hotkey in Preferences

### 2. Streaming Everywhere

- **Live Transcription:** Partial results shown as user speaks
- **Streaming LLM:** Response tokens appear incrementally
- **Early TTS:** Audio begins as soon as first sentence is complete

### 3. Predictability Over Cleverness

- **Intent Preview:** Show what will happen before executing
- **No Surprises:** Actions should be obvious from the command
- **Consistent Behavior:** Same command = same result

### 4. Confirmation Gates

**Actions requiring confirmation:**
- Create event/reminder
- Delete event/reminder
- Send communications (future)

**Confirmation timeout:** 1 minute (proposal auto-cancels if no response)

**Actions without confirmation:**
- Query calendar
- Search contacts
- List reminders
- Open app/URL

### 5. Auditability

- Every action logged with timestamp
- Clear "what changed" record
- Accessible in Preferences

### 6. Private Mode

- Toggle to disable voice output
- Text-only display option
- For use in quiet environments

---

## Performance Requirements

| Metric | Target | Notes |
|:-------|:-------|:------|
| ASR Partials | Every 200-400ms | Responsive transcription feedback |
| End-of-Speech Finalization | ≤300ms | Quick recognition of speech end |
| LLM Time-to-First-Token | <400ms | After model warmup |
| TTS Audio Start | ~500ms | For short responses |
| PTT Release → First Audio | <1.0s median | End-to-end latency goal |

### Stability Requirements

- No memory growth over 30 minutes of continuous use
- Graceful degradation:
  - **TTS fails:** Always show text response + error message, fallback to AVSpeechSynthesizer
  - **LLM fails:** Dictation-only mode (show ASR transcript + error message + retry button)
- Clean shutdown and restart handling

---

## Permissions & Privacy

### Required Permissions

| Permission | Purpose | Fallback |
|:-----------|:--------|:---------|
| Microphone | Voice input | App non-functional without |
| Accessibility | Global hotkey | Menu bar activation only |
| Calendar | Event management | Calendar features disabled |
| Reminders | Task management | Reminders features disabled |
| Contacts | Contact lookup | Contacts features disabled |

### Privacy Guarantees

- **Runs Locally:** All inference happens on-device; no data uploaded
- **Download Only:** Network used only for model downloads and app update checks
- **Minimal Data Retention:** Only conversation context needed for current session
- **User-Controlled Logging:** Audit log stored locally, user can clear
- **No Telemetry:** No usage data sent anywhere

---

## Non-Goals (v1)

The following are explicitly **out of scope** for v1:

| Feature | Rationale |
|:--------|:----------|
| Always-listening wake word | Privacy concerns; PTT sufficient for v1 |
| General Mac automation | Focus on doing core features well first |
| Local Mail inbox reading | Complex privacy implications |
| Cloud-based features | Local-first philosophy |
| Third-party integrations | Keep scope manageable |

---

## Future Phases

### Phase 2

- **Optional Wake Word:** Opt-in "always listening" mode
- **Conversation Memory:** Remember context across sessions
- **Mail via APIs:** Integration with mail providers (not local reading)
- **Expanded Tools:** Notes, Files search

### Phase 3

- **On-Device Embeddings:** Local semantic search ("what did I promise last week?")
- **Multi-Modal:** Screenshots, document understanding
- **Workflow Automation:** User-defined action sequences

---

## Success Metrics

### Quantitative

| Metric | Target |
|:-------|:-------|
| End-to-end latency (PTT release → audio) | <1.0s median |
| Calendar action success rate | >95% |
| ASR accuracy (WER) | <10% for clear speech |
| App stability (crash-free sessions) | >99% |

### Qualitative

- User feels in control of the assistant
- Actions feel predictable and safe
- Voice interaction is faster than manual for supported tasks
- Privacy confidence: users trust data stays local

---

## Appendix: Tool Schema Reference

See `docs/stories/ARCHITECTURE.md` for detailed tool implementation specifications.

### Tool Categories

| Category | Tools | Confirmation Required |
|:---------|:------|:---------------------|
| Calendar | query, findSlots, create, delete | create, delete |
| Reminders | list, create, complete, delete | create, delete |
| Contacts | search, lookup | None |
| System | openApp, openURL | None |
