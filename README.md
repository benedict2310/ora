<div align="center">
  <img src="docs/legacy/v1/media/app-icon.png" alt="Ora" width="128" height="128">

  # Ora

  **Privacy-first macOS voice assistant powered by on-device AI**

  [![macOS](https://img.shields.io/badge/macOS-26.0+-blue.svg)](https://www.apple.com/macos)
  [![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
  [![License: Source Available](https://img.shields.io/badge/License-Source%20Available-blue.svg)](LICENSE)
  [![Release](https://img.shields.io/github/v/release/benedict2310/ora)](https://github.com/benedict2310/ora/releases)

  [Download](https://github.com/benedict2310/ora/releases/latest) • [Documentation](docs/) • [Contributing](#contributing)
</div>

---

## ✨ What is Ora?

Ora is a **local-first macOS voice assistant** that focuses on a small set of high-value workflows: Calendar, Reminders, Contacts, and minimal safe system actions.

The v2 direction is intentionally subtractive: keep the assistant fast, reliable, auditable, and private instead of growing into a broad automation platform. Legacy v1 planning material is archived under [`docs/legacy/v1/`](docs/legacy/v1/).

```text
Voice or text input
    ↓
Parakeet ASR / typed request
    ↓
Local MLX LLM structured output
    ↓
Core action host + confirmation gates
    ↓
Overlay answer + optional Kokoro TTS + audit record
```

### Demo

https://github.com/benedict2310/ora/assets/demo.mp4

> **Note:** Video shows Ora managing calendar events via voice commands.

---

## 🎯 v2 Core Features

- **🔒 Local-first by default** — Speech recognition, reasoning, and speech synthesis run on-device.
- **🎤 Push-to-talk** — Hotkey activation (`⌥Space`) with menu bar control.
- **⚡ Streaming voice loop** — Live transcription, structured reasoning, and optional spoken responses.
- **🗓 Calendar actions** — Query schedules, find slots, and propose confirmed mutations.
- **✅ Reminders actions** — List, create, update, complete, and delete reminders with guardrails.
- **👥 Contacts lookup** — Resolve people for lookup and invitation workflows.
- **🖥 Minimal system actions** — Open apps, URLs/searches, and relevant settings.
- **📝 Audit trail** — Mutations answer what changed, when, why, and whether the user confirmed.
- **📈 Local telemetry** — Conversation flow, latency, cancellation, TTS/STT, and barge-in behavior are observable without logging private content.
- **🔄 Auto-updates** — Signed release builds update via Sparkle.

Out of v2 core: mail, messages, notes, skills/scripts, semantic memory, research/background agents, vision, and cloud-provider routing. See [`docs/product/pdrs/`](docs/product/pdrs/) for accepted product decisions.

---

## 📦 Download

**Latest Release:** [Ora (Releases)](https://github.com/benedict2310/ora/releases/latest)

### Installation

1. Download `Ora-{version}.dmg` from [Releases](https://github.com/benedict2310/ora/releases)
2. Open the DMG and drag **Ora.app** to Applications
3. Launch Ora and grant requested permissions
4. Press **⌥Space** to activate

> Note: Sparkle auto-updates are intended for the signed release build installed in `/Applications`. Developer builds disable update checks.

### Requirements

| Requirement | Minimum | Recommended |
|:------------|:--------|:------------|
| **macOS** | 26.0 (Tahoe) | Latest |
| **Chip** | Apple Silicon (M1) | M2 Pro or better |
| **RAM** | 16GB | 32GB |

---

## 🚀 Getting Started

### For Users

1. Download from [Releases](https://github.com/benedict2310/ora/releases)
2. Install and launch
3. On first run, Ora downloads required on-device models (ASR + LLM + TTS)
4. Grant permissions when prompted:
   - **Microphone** — Voice input
   - **Calendar** — Event management
   - **Reminders** — Task management
   - **Contacts** — Contact lookup
   - **Accessibility** — Global hotkey if required by the current build
5. Press **⌥Space** and start talking

### For Developers

```bash
# Install dependencies
brew install xcodegen

# Clone repository
git clone https://github.com/benedict2310/ora.git
cd ora

# Build and run
./build.sh run
```

**Build Commands:**

| Command | Description |
|:--------|:------------|
| `./build.sh` | Build only |
| `./build.sh run` | Build and launch |
| `./build.sh test` | Run the current test gate |
| `./build.sh test-tsan` | Run tests with Thread Sanitizer enabled |
| `./build.sh clean` | Clean build artifacts |
| `./build.sh reset-perms` | Reset macOS permissions |

---

## 🏗️ Architecture

Ora v2 is organized around a small local assistant loop:

1. **Input** → push-to-talk or typed text
2. **ASR** → FluidAudio Parakeet for speech-to-text
3. **LLM** → MLX Swift local model with compact structured output
4. **Actions** → Calendar, Reminders, Contacts, and minimal System adapters
5. **Confirmation** → required before state-changing actions
6. **TTS/UI** → Kokoro speech output and compact overlay
7. **Audit + telemetry** → local mutation history and debuggable per-turn traces

**Tech Stack:**
- **Language:** Swift 6.0 with strict concurrency
- **Frameworks:** AppKit, SwiftUI, AVFoundation, EventKit, Contacts, OSLog
- **ML Runtime:** MLX Swift for on-device inference
- **Build System:** XcodeGen for project generation

See [`docs/`](docs/) for current product and architecture docs.

---

## 📂 Project Structure

```text
Ora/
├── Ora/                    # Main app source
│   ├── App/                # Composition and feature set
│   ├── Interaction/        # Assistant turns and state transitions
│   ├── Actions/            # Calendar, Reminders, Contacts, System contracts/adapters
│   ├── Telemetry/          # Local event, logging, and signpost spine
│   ├── ASR/                # Speech recognition adapters
│   ├── LLM/                # Local language model runtime
│   ├── TTS/                # Text-to-speech runtime
│   └── UI/                 # Overlay, preferences, confirmation UI
├── OraCoreTests/           # Fast v2 contract tests
├── OraTests/               # Legacy/full app tests during migration
├── docs/                   # Current v2 docs plus legacy archive
│   ├── architecture/
│   ├── product/
│   └── legacy/v1/
├── scripts/                # Build and release scripts
├── project.yml             # XcodeGen configuration
└── build.sh                # Build helper script
```

---

## 🛠️ Development

### Running Tests

```bash
./build.sh test
```

The default gate is intentionally fast and high-signal. Use named commands for slower legacy, permission, model, audio, or Thread Sanitizer checks.

### Debugging

View live logs:
```bash
./build.sh logs
```

View a specific category:
```bash
./build.sh logs --category telemetry
```

Ora v2 telemetry should expose non-sensitive fields such as event names, turn IDs, durations, counts, action names, and result categories as visible/public log fields. Transcript text, prompts, audio, contact data, calendar/reminder content, URLs, and raw tool payloads must be omitted or private by default.

### Permissions

If permissions stop working after rebuild:
```bash
./build.sh reset-perms
```

macOS TCC tracks permissions by bundle ID + code hash. Every rebuild changes the hash, so local development builds may need a reset and re-grant.

---

## 🤝 Contributing

Contributions are welcome. Please keep changes aligned with the accepted v2 scope in [`docs/product/`](docs/product/) and [`docs/architecture/`](docs/architecture/).

**Areas where we'd love help:**
- 🐛 Bug fixes and performance improvements
- 📝 Documentation and examples
- 🎨 Focused UI/UX improvements
- 🧪 High-signal tests for core contracts and supported workflows

### Development Setup

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/amazing-feature`
3. Make your changes
4. Run tests: `./build.sh test`
5. Commit: `git commit -m "feat: add amazing feature"`
6. Push: `git push origin feat/amazing-feature`
7. Open a Pull Request

---

## 📄 License

Ora is source available — you can read and audit the code, but redistribution and commercial use require explicit written permission.
See [LICENSE](LICENSE) for full terms.

© 2026 Benedict Evert / Futurelab Studio. All rights reserved.
Contact: benedict.bleimschein@gmail.com

---

## 🙏 Acknowledgments

Built with these amazing open-source projects:

- [MLX Swift](https://github.com/ml-explore/mlx-swift) — Apple Silicon ML framework
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Streaming ASR
- [Sparkle](https://github.com/sparkle-project/Sparkle) — Auto-update framework
- [Qwen](https://huggingface.co/Qwen) — Local language models
- [Kokoro TTS](https://huggingface.co/hexgrad/Kokoro-82M) — Text-to-speech

---

<div align="center">
  Made with ❤️ for privacy-conscious Mac users

  [⭐ Star this repo](https://github.com/benedict2310/ora) if you find it useful!
</div>
