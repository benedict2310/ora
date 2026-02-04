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
| `./build.sh sign` | Build, sign with Developer ID, and notarize for distribution |

## Releases

Ora uses a local signing workflow for creating releases:

### Creating a Release

```bash
# 1. Sign and notarize the app (takes 2-5 min for notarization)
./build.sh sign

# You'll be prompted for:
# - Apple ID (your developer account email)
# - App-specific password (from appleid.apple.com)
# - Team ID (from developer.apple.com)

# 2. The script will:
#    - Build the app
#    - Sign with Developer ID
#    - Notarize with Apple
#    - Create and sign a DMG

# 3. Create GitHub Release
VERSION="1.0.1"
gh release create "v${VERSION}" "./Ora-${VERSION}.dmg" \
  --title "Ora v${VERSION}" \
  --notes "Release notes here"

# 4. Update Sparkle appcast (for auto-updates)
TOOLS_DIR=$(./scripts/generate-appcast.sh --print-tools-dir)
PRIVATE_KEY="<your-sparkle-private-key>"

# Sign DMG with Sparkle
scripts/ci-release.sh sparkle-sign "./Ora-${VERSION}.dmg" "$TOOLS_DIR" "$PRIVATE_KEY"

# Generate appcast
mkdir -p build/appcast
cp "./Ora-${VERSION}.dmg" build/appcast/
scripts/ci-release.sh generate-appcast \
  "build/appcast/Ora-${VERSION}.dmg" "$TOOLS_DIR" "$VERSION" "$PRIVATE_KEY"

# Push to ora-updates repository
cd /tmp
git clone https://github.com/benedict2310/ora-updates.git
cd ora-updates
cp /path/to/ora/build/appcast/appcast.xml .
git add appcast.xml
git commit -m "release: update appcast for v${VERSION}"
git push
```

### Auto-Updates

Ora includes Sparkle for automatic updates:
- **Appcast URL:** https://raw.githubusercontent.com/benedict2310/ora-updates/main/appcast.xml
- **Updates Repository:** https://github.com/benedict2310/ora-updates

Users will be notified of new releases automatically when launching the app.

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
