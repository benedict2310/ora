# Ora

A privacy-first macOS voice assistant that runs fully on-device.

```
Voice → (Parakeet ASR) → (MLX + Qwen 2.5) → (Kokoro TTS) → Voice/UI
```

## Features

- **100% Local Processing** - All inference runs on-device using Apple Silicon acceleration
- **Push-to-Talk** - Hotkey activation (default: `⌥Space`) with menu bar control
- **Streaming Pipeline** - Live transcription, streaming LLM tokens, early TTS start
- **Agentic Tools** - Calendar, Reminders, Contacts, and System actions
- **Audit Trail** - Every action logged for transparency

## Requirements

- **macOS:** 26 (Tahoe) or later
- **Chip:** Apple Silicon (M1 or later)
- **RAM:** 16GB minimum, 32GB recommended
- **Tools:** Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Quick Start

```bash
# Install XcodeGen (if not already installed)
brew install xcodegen

# Build and run
./build.sh run
```

## Build Commands

| Command | Description |
|:--------|:------------|
| `./build.sh` | Build only |
| `./build.sh run` | Build and launch (kills previous instance) |
| `./build.sh clean` | Clean build artifacts and regenerate project |
| `./build.sh reset-perms` | Reset TCC permissions after rebuild |

## Project Structure

```
Ora/
├── Ora/                    # Main app source
│   ├── main.swift          # Entry point
│   ├── AppDelegate.swift   # App lifecycle
│   ├── Info.plist          # App configuration
│   └── UI/                 # UI components
│       └── StatusBarController.swift
├── OraTests/               # Unit tests
├── docs/                   # Documentation
│   └── stories/            # Implementation stories
├── project.yml             # XcodeGen configuration
└── build.sh                # Build script
```

## Development

### Running Tests

```bash
xcodebuild test -project Ora.xcodeproj -scheme Ora
```

### Regenerating Xcode Project

The Xcode project is generated from `project.yml`:

```bash
xcodegen generate
```

### Permissions

Ora requires the following permissions:
- **Microphone** - Voice input
- **Calendar** - Event management
- **Reminders** - Task management
- **Contacts** - Contact lookup
- **Accessibility** - Global hotkey

If permissions stop working after a rebuild, run:
```bash
./build.sh reset-perms
```

## Architecture

Ora uses a streaming pipeline architecture:

1. **Audio Capture** - Real-time microphone input via AVAudioEngine
2. **ASR** - FluidAudio Parakeet for speech-to-text
3. **LLM** - MLX Swift with Qwen 2.5 for reasoning
4. **Tools** - Native macOS integrations (EventKit, Contacts)
5. **TTS** - Kokoro MLX for speech synthesis

See [docs/stories/ARCHITECTURE.md](docs/stories/ARCHITECTURE.md) for details.

## License

Private - All rights reserved.
