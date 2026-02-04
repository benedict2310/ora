<div align="center">
  <img src="docs/media/app-icon.png" alt="Ora" width="128" height="128">

  # Ora

  **Privacy-first macOS voice assistant powered by on-device AI**

  [![macOS](https://img.shields.io/badge/macOS-26.0+-blue.svg)](https://www.apple.com/macos)
  [![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
  [![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
  [![Release](https://img.shields.io/github/v/release/benedict2310/ora)](https://github.com/benedict2310/ora/releases)

  [Download](https://github.com/benedict2310/ora/releases/latest) • [Documentation](docs/) • [Contributing](#contributing)
</div>

---

## ✨ What is Ora?

Ora is a **fully on-device voice assistant** for macOS that puts your privacy first. Every piece of processing happens locally on your Mac — no data ever leaves your machine.

```
Voice → Parakeet ASR → MLX + Qwen 2.5 → Kokoro TTS → Voice/UI
```

### Demo

https://github.com/benedict2310/ora/assets/demo.mp4

> **Note:** Video shows Ora managing calendar events via voice commands

---

## 🎯 Features

- **🔒 100% Local Processing** — All inference runs on-device using Apple Silicon acceleration
- **🎤 Push-to-Talk** — Hotkey activation (⌥Space) with menu bar control
- **⚡ Streaming Pipeline** — Live transcription, streaming LLM tokens, early TTS start
- **🤖 Agentic Tools** — Calendar, Reminders, Contacts, and System integrations
- **📝 Audit Trail** — Every action logged for transparency
- **🔄 Auto-Updates** — Seamless updates via Sparkle

---

## 📦 Download

**Latest Release:** [Ora v1.0.0](https://github.com/benedict2310/ora/releases/latest)

### Installation

1. Download `Ora-{version}.dmg` from [Releases](https://github.com/benedict2310/ora/releases)
2. Open the DMG and drag **Ora.app** to Applications
3. Launch Ora and grant requested permissions
4. Press **⌥Space** to activate

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
3. Grant permissions when prompted:
   - **Microphone** — Voice input
   - **Calendar** — Event management
   - **Reminders** — Task management
   - **Contacts** — Contact lookup
   - **Accessibility** — Global hotkey
4. Press **⌥Space** and start talking!

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
| `./build.sh test` | Run tests |
| `./build.sh clean` | Clean build artifacts |
| `./build.sh reset-perms` | Reset macOS permissions |

---

## 🏗️ Architecture

Ora uses a streaming pipeline architecture for maximum responsiveness:

1. **Audio Capture** → Real-time microphone input via AVAudioEngine
2. **ASR** → FluidAudio Parakeet for streaming speech-to-text
3. **LLM** → MLX Swift with Qwen 2.5 (7B) for reasoning
4. **Tools** → Native macOS integrations (EventKit, Contacts)
5. **TTS** → Kokoro MLX for natural speech synthesis

**Tech Stack:**
- **Language:** Swift 6.0 with strict concurrency
- **Frameworks:** AppKit, SwiftUI, EventKit, Contacts
- **ML Runtime:** MLX Swift for on-device inference
- **Build System:** XcodeGen for project generation

See [docs/stories/ARCHITECTURE.md](docs/stories/ARCHITECTURE.md) for detailed architecture documentation.

---

## 📂 Project Structure

```
Ora/
├── Ora/                    # Main app source
│   ├── Audio/              # Audio capture and VAD
│   ├── ASR/                # Speech recognition (Parakeet)
│   ├── LLM/                # Language model (Qwen 2.5)
│   ├── Tools/              # Calendar, Reminders, Contacts
│   ├── TTS/                # Text-to-speech (Kokoro)
│   ├── UI/                 # AppKit + SwiftUI interface
│   └── Orchestration/      # Core app logic
├── OraTests/               # Unit tests
├── docs/                   # Documentation
│   └── stories/            # Implementation stories
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

### Debugging

View live logs:
```bash
./build.sh logs
```

View specific category:
```bash
./build.sh logs --category llm
```

### Permissions

If permissions stop working after rebuild:
```bash
./build.sh reset-perms
```

macOS TCC tracks permissions by bundle ID + code hash. Every rebuild changes the hash, so you need to reset and re-grant permissions.

---

## 🤝 Contributing

Contributions are welcome! Please read our [Contributing Guidelines](CONTRIBUTING.md) first.

**Areas where we'd love help:**
- 🐛 Bug fixes and performance improvements
- 📝 Documentation and examples
- 🌍 Internationalization and localization
- 🎨 UI/UX improvements
- 🧪 Additional test coverage

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

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

Built with these amazing open-source projects:

- [MLX Swift](https://github.com/ml-explore/mlx-swift) — Apple Silicon ML framework
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Streaming ASR
- [Sparkle](https://github.com/sparkle-project/Sparkle) — Auto-update framework
- [Qwen 2.5](https://huggingface.co/Qwen) — Language model
- [Kokoro TTS](https://huggingface.co/hexgrad/Kokoro-82M) — Text-to-speech

---

<div align="center">
  Made with ❤️ for privacy-conscious Mac users

  [⭐ Star this repo](https://github.com/benedict2310/ora) if you find it useful!
</div>
