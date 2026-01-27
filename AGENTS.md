# Ora - AI Agent & Developer Context

> **Note:** This file consolidates project context, workflows, and architectural details. It serves as the primary source of truth for AI agents and developers working on this repository.
>
> **Minimum macOS:** 26 (Tahoe) | **Chip:** Apple Silicon (M1+) | **RAM:** 16GB recommended, 32GB best

---

## Repository Guidelines

### Project Summary

**Ora** is a privacy-first macOS voice assistant that runs fully on-device:

```
Voice → (FluidAudio Parakeet) → (MLX + Qwen 2.5) → (Kokoro TTS) → Voice/UI
```

**Primary differentiator:** Fast, reliable, auditable actions (Calendar/Reminders/Contacts first), minimal cloud, and a UI that makes the assistant feel predictable and safe.

### Project Structure & Modules
- `Ora/Ora`: Main macOS app source (Audio, ASR, LLM, Tools, TTS, UI). Keep changes small and reuse existing helpers.
- `Ora/OraTests`: XCTest coverage for audio, transcription, LLM, tools; mirror new logic with focused tests.
- `scripts/`: Build/sign helpers (`build.sh`, signing scripts).
- `docs/`: Documentation (architecture, stories, design).
- `Vendor/`: External inference engines (MLX, Parakeet, Kokoro TTS).
- `project.yml`: XcodeGen configuration (generates `.xcodeproj`).

### Key Resources
| Resource | Location | Purpose |
|:---------|:---------|:--------|
| **System Prompt** | `Ora/Resources/system-prompt.txt` | LLM system prompt template with `{{variable}}` placeholders. Edit this file to change assistant behavior without modifying code. |

### Documentation Organization (MANDATORY)

**Always maintain a clean project structure:**

| Document Type | Location | Examples |
|:--------------|:---------|:---------|
| User stories | `docs/stories/` | Feature specs, PRD, implementation plans |
| Reports & investigations | `docs/` (in appropriate subfolders) | Performance reports, bug investigations, audits |
| Architecture docs | `docs/stories/` | System design, component diagrams |
| Setup & guides | `docs/` | Environment setup, testing guides |

- **All user stories MUST be collected in `docs/stories/`**
- **All reports, investigations, or other documents MUST be collected in appropriate folders under `docs/`**
- Create subfolders as needed (e.g., `docs/reports/`, `docs/investigations/`)
- Keep documentation up-to-date when implementation changes

### Build, Test, Run

**Build script commands:**
| Command | When to Use |
|:--|:--|
| `./build.sh` | Build only, don't launch |
| `./build.sh run` | Build and launch (kills old instance first) |
| `./build.sh clean` | Fresh start (removes DerivedData) |
| `./build.sh reset-perms` | Reset TCC permissions (Accessibility, Calendar, Reminders, Contacts) |
| `./build.sh test` | Run tests with token-optimized output |
| `./build.sh test-tsan` | Run tests with Thread Sanitizer enabled |
| `./build.sh logs` | Stream unified logs (includes debug level) |
| `./build.sh logs --category <name>` | Stream logs for specific category (e.g., `chunker`, `tts`, `llm`) |
| `./build.sh open-results` | Open `.xcresult` bundle in Xcode |

### Viewing Logs (macOS Unified Logging)

**Important:** macOS filters out debug and info level logs by default. Use these commands to see all log levels:

**Stream logs in real-time:**
```bash
# All Ora logs (recommended)
./build.sh logs

# Specific category
./build.sh logs --category chunker
./build.sh logs --category tts
./build.sh logs --category llm
```

**View recent logs (last N minutes):**
```bash
# All levels including debug/info (REQUIRED for most debugging)
log show --debug --info --predicate 'subsystem == "com.ora.app"' --last 5m

# Specific category
log show --debug --info --predicate 'subsystem == "com.ora.app" AND category == "chunker"' --last 5m

# Search for specific text
log show --debug --info --predicate 'subsystem == "com.ora.app"' --last 5m | grep -i "search term"
```

**Log categories:** `audio`, `asr`, `llm`, `tools`, `tts`, `chunker`, `ui`, `orchestration`, `permissions`, `models`, `persistence`

**Log levels (in order of severity):**
- `.debug` - Detailed debugging (filtered by default, use `--debug` flag)
- `.info` - General flow info (filtered by default, use `--info` flag)
- `.notice` - Important events (always visible)
- `.error` - Errors that don't crash
- `.fault` - Critical errors with stack traces

**Common workflows:**

```bash
# Normal development
./build.sh run

# Permissions stopped working (prompt keeps appearing)
./build.sh reset-perms
./build.sh run
# Grant permissions when prompted

# Fresh start (new clone, weird build issues)
./build.sh clean
./build.sh reset-perms
./build.sh run
```

**Why `reset-perms`?** macOS TCC tracks permissions by bundle ID + CDHash. Every rebuild changes the CDHash, so old permission grants don't apply. `reset-perms` clears stale entries so the next grant applies to the current build.

**Skip setup wizard (for testing):**
```bash
# Mark setup as complete to bypass the setup wizard
defaults write com.ora.app "com.ora.setupComplete" -bool true

# Reset hotkey to default (Option+Space) if it was changed
defaults delete com.ora.app "com.ora.hotkeyConfiguration"

# Then run the app
./build.sh run
```

**Other commands:**
- **Run tests:** `./build.sh test` (preferred) or `xcodebuild test -project Ora.xcodeproj -scheme Ora`.
- **Restart app manually:** `killall Ora 2>/dev/null || true; open -n build/Build/Products/Release/Ora.app`.

### Test Output Policy (Token Optimization)

When running tests, report results minimally:
- **Pass:** Only report the summary line (e.g., `✅ Tests: 42/42 passed`)
- **Fail:** Report summary + failure list + artifact paths (`.artifacts/TestResults.xcresult`, `.artifacts/xcodebuild.test.log`)
- **Never paste** full xcodebuild logs or large JSON blobs into chat

For detailed triage workflows, load the `ora-testing` skill.

### Coding Style & Naming
- Favor small, typed structs/enums; maintain existing `MARK` organization.
- Use descriptive symbols; match current commit tone.
- 4-space indent; explicit `self` is intentional—do not remove.
- Keep bridging code (Objective-C++) minimal and well-documented.
- Prefer Swift Concurrency (async/await, actors) over GCD where possible.

### Testing Guidelines
- Add/extend XCTest cases under `Ora/OraTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods).
- Always run tests before handoff; add fixtures for new parsing/formatting scenarios.
- After any code change, rebuild and test before declaring completion.
- **Preferred test command:** `./build.sh test` (token-optimized output, saves artifacts to `.artifacts/`)
- **Thread Sanitizer:** `./build.sh test-tsan` or use the `Ora-TSan` scheme directly.
- **Debugging failures:** `./build.sh open-results` to inspect `.xcresult` bundle.

### Review Learnings (Keep Concise)
- Keep action handlers alive; do not `weak` the only instance (menu actions must execute).
- Tear down `NSStatusItem` on shutdown to avoid duplicate menu icons.
- Ensure menu actions have observable behavior and are covered by tests.
- Permission flows: use correct APIs (events vs reminders), map `.authorized`/`.writeOnly` correctly, and prompt accessibility before opening Settings.
- Permission checks must update shared state and post notifications.
- Implement required/optional permission requests as specified; keep docs and code aligned.
- Cover request flows and settings opening in tests; record manual E2E checklists for permission/menu flows.
- **Permission prompt tracking (CRITICAL):** Permission requests MUST go through `PermissionsManager.shared.request()` which handles `PermissionPromptTracker` calls centrally. Do NOT add tracker calls to individual permission files (`MicrophonePermission`, `EventKitPermission`, `ContactsPermission`) - this causes double tracking which breaks focus recovery. The tool-level providers (`EventStoreProvider`, `RemindersStoreProvider`) have their own tracker calls for when tools bypass `PermissionsManager`.
- **MLX GPU memory (CRITICAL):** MLX caches Metal GPU buffers for reuse, but without limits this cache grows unbounded (15GB+ observed). Always: (1) Set `GPU.set(cacheLimit:)` on model load (512MB recommended), (2) Call `GPU.clearCache()` after each LLM/TTS generation. See `LLMService.swift` and `KokoroEngine.swift` for examples.
- **macOS Logger privacy:** By default, macOS redacts dynamic string interpolation in `Logger` calls as `<private>`. To see actual values during debugging, use `privacy: .public`: `logger.error("Result: '\(String(text), privacy: .public)'")`). **IMPORTANT:** Remove `.public` privacy modifiers before merging - they should only be used temporarily for debugging, never in production code.

### Commit & PR Guidelines
- Commit messages: short imperative clauses (e.g., "Add calendar tool", "Fix ASR latency"); keep commits scoped.
- PRs/patches should list summary, commands run, screenshots/GIFs for UI changes, and linked issue/reference when relevant.

### Agent Notes
- Use the provided scripts and XcodeGen; avoid adding dependencies or tooling without confirmation.
- Validate behavior against the freshly built bundle; restart via `./build.sh run` to avoid running stale binaries.
- After any code change that affects the app, always rebuild with `./build.sh` and restart the app before validating behavior.
- If you edited code, run `./build.sh run` before handoff; it kills old instances, builds, and relaunches.
- Keep pipeline stages isolated: ASR, LLM, Tools, and TTS should have clear boundaries and not leak state.
- Tool implementations must follow the guardrails pattern (confirmation for state-changing actions).

---

## 1. Project Overview

**Ora** is a native macOS voice assistant powered by local AI inference. All processing happens on-device using Apple Silicon acceleration.

**Key Features:**
- **Local Processing:** All inference runs on-device; no data uploaded.
- **Push-to-Talk (PTT):** Hotkey + menubar mic button activation.
- **Streaming Pipeline:**
  - Live partial transcription (ASR)
  - Streaming LLM text tokens
  - Early TTS start (sentence chunking)
- **Agentic Tools:** Calendar, Reminders, Contacts, System actions with strong guardrails.
- **Auditability:** Every tool call logged with what was changed, when, and why.

**Tech Stack:**
- **Language:** Swift 6.0 with strict concurrency (AppKit + SwiftUI)
- **Core Frameworks:** `AVFoundation`, `EventKit`, `Contacts`, `Metal`, `Accelerate`, `SwiftData`
- **ASR Engine:** FluidAudio Parakeet (streaming, Metal-accelerated)
- **LLM Runtime:** MLX Swift (`mlx-swift-lm`)
- **LLM Model:** Qwen 2.5 (7B primary, 3B fallback) - 4-bit quantized
- **TTS Engine:** Kokoro MLX (fallback: AVSpeechSynthesizer)
- **Persistence:** SwiftData (sessions, audit logs, model metadata)
- **Project Management:** `XcodeGen` (generates `.xcodeproj` from `project.yml`)
- **Activation Hotkey:** `⌥Space` (customizable in Preferences)

**Target Users:**
- Power users who want a fast assistant that actually executes (calendar, tasks, contacts)
- Privacy-minded users who prefer on-device inference
- Accessibility users (voice-first workflows)

---

## 2. Git Workflow (CRITICAL)

**Always follow this workflow. Never commit directly to `main`.**

1.  **Create a Feature Branch:**
    ```bash
    git checkout -b fix/descriptive-name     # For bug fixes
    git checkout -b feat/descriptive-name    # For new features
    ```
    *Naming conventions:* `fix/`, `feat/`, `refactor/`, `docs/`, `test/`.

2.  **Commit Changes:**
    ```bash
    git add .
    git commit -m "feat: description of change"
    ```

3.  **Push & PR:**
    Push to origin and create a Pull Request against `main`.

4.  **Cleanup:**
    Delete the feature branch after merging.

**Important**: There is an ./agent-tools folder in the root of the project. This is for quick tests, helper scripts and testing. This folder is gitignored and shouldn't be commited per design.

### Branch Hygiene & Multi-Agent Coordination (MANDATORY)

- Always sync `main` before branching: `git fetch origin`, `git checkout main`, `git pull origin main`.
- Use one branch per story/bug; include the story/bug ID in the branch name when possible.
- Keep branches short-lived. If `main` moves significantly, **do not merge** an old branch; create a new branch from current `main` and cherry-pick the relevant commits (no rebase unless explicitly approved).
- Before opening a PR, verify scope: `git log --oneline main..HEAD` and `git diff --stat main...HEAD`. If unrelated files show up, split into separate branches.
- When multiple agents work in parallel, nominate a single owner per story/bug and record active branches in the story doc (or add a dated report in `docs/reports/` when a branch is abandoned).
- If a stale branch is discovered, document it (story note or report), reopen the story if needed, and retire the branch.
- After merge, delete local and remote branches to avoid stale branch drift.

### Branch Completion Rules (CRITICAL - PREVENTS LOST WORK)

**NEVER leave a branch unmerged after completing work:**

1. **Immediate PR after fix:** When a bug fix or feature is complete and tested, create a PR immediately.
2. **Merge before context switch:** Before starting new work, ensure all completed branches are merged to main.
3. **No orphan branches:** A branch with working code that isn't merged is lost work waiting to happen.

**Before ending a session, verify:**
```bash
# Check for unmerged branches with your work
git branch --no-merged main

# If branches exist, either:
# 1. Create PRs and merge them
# 2. Document why they're intentionally unmerged (e.g., WIP, blocked)
```

**Orphan branch audit (run periodically):**
```bash
# List all branches not in main
git branch -a --no-merged main

# For each branch, decide:
# - Merge it (if work is complete)
# - Document and delete (if superseded)
# - Keep with documented reason (if intentionally WIP)
```

**If you discover orphan branches with completed work:**
1. Check if the work is still needed (may have been reimplemented)
2. If needed: cherry-pick or re-apply the fix to current main
3. Document the orphan in `docs/stories/bugs/` if it contains valuable alternative approaches
4. Delete the orphan branch after preserving any valuable code/docs

### Bug Fixes (Non-Story Work)

- Use the same branch hygiene as above even when not using the implement-story skill.
- If a bug has a story/bug doc, update it with branch name, commit count, and verification notes before PR.
### Story Work (When Implementing Specs)

- Prefer the implement-story skill for story work; if not used, still follow the same branch hygiene and doc updates.

### Git Safety Rules (MANDATORY)

**ALWAYS COMMIT, NEVER STASH:**
- **NEVER use `git stash`** to save finished or in-progress implementation work. Stashed code is invisible and easily lost.
- **ALWAYS commit your work** to a branch, even if it's incomplete. Use a WIP commit message like `wip: partial implementation of X`.
- If you need to switch contexts, commit to a feature branch first, then switch.

**DANGEROUS COMMANDS - REQUIRE EXPLICIT USER PERMISSION:**
These commands can cause data loss. **NEVER run them without the user explicitly requesting it:**
- `git stash` / `git stash drop` / `git stash clear`
- `git reset --hard`
- `git clean -fd`
- `rm -rf` on untracked files or directories (always ask or use `git clean -n` first)
- `git checkout -- <file>` (discards changes)
- `git branch -D` (force delete)
- `git push --force` / `git push -f`
- `git rebase` (can rewrite history)
- Any command with `--force` or `-f` flags

**If you find stashed or uncommitted work:**
- Alert the user immediately
- Help recover and commit it to a proper branch
- Never assume stashed code is unimportant

---

## 3. Architecture & Pipeline

### Core Pipeline Flow

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Audio     │───▶│    ASR      │───▶│    LLM      │───▶│    TTS      │
│  Capture    │    │  (Parakeet) │    │  (Reasoning)│    │  (Speech)   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                         │                   │
                         ▼                   ▼
                   ┌───────────┐      ┌─────────────┐
                   │    UI     │◀─────│   Tools     │
                   │ (Overlay) │      │ (Actions)   │
                   └───────────┘      └─────────────┘
```

### Core Components

*   **Audio Pipeline (`Audio/`):**
    *   `AudioCapture.swift`: Microphone input (AVAudioEngine).
    *   `VAD.swift`: Voice Activity Detection for speech boundaries.
    *   `AudioBuffer.swift`: Lock-free buffer for thread-safe audio transfer.

*   **ASR (`ASR/`):**
    *   `ParakeetEngine.swift`: Swift wrapper for Parakeet ASR.
    *   `TranscriptionStream.swift`: Handles partial/final transcription events.
    *   Target: partials every 200-400ms, finalization within 300ms of speech stop.

*   **LLM / Reasoning (`LLM/`):**
    *   `LLMEngine.swift`: MLX Swift wrapper for Qwen 2.5 inference.
    *   `ToolCaller.swift`: Parses tool calls from LLM output (JSON schema).
    *   `ConversationManager.swift`: Manages context and multi-turn dialogue.
    *   `SystemPromptBuilder.swift`: Builds prompts with current date/time/timezone.
    *   `JSONValidator.swift`: Validates LLM output, handles retry on failure.
    *   Supports multi-step loops: plan → tool → observe → finalize.
    *   **Structured Output:** Validation + retry (max 3 attempts) since MLX lacks grammar constraints.

*   **Tools (`Tools/`):**
    *   `CalendarTool.swift`: Query, find slots, create/delete events (EventKit).
    *   `RemindersTool.swift`: Create, list reminders (EventKit).
    *   `ContactsTool.swift`: Search contacts by name/email (Contacts framework).
    *   `SystemTool.swift`: Open apps, open URLs.
    *   `ToolRegistry.swift`: Central registry for all available tools.
    *   `ToolGuardrails.swift`: Confirmation logic for state-changing actions.

*   **TTS (`TTS/`):**
    *   `TTSEngine.swift`: Kokoro MLX text-to-speech (AVSpeechSynthesizer fallback).
    *   `SentenceChunker.swift`: Streams audio as sentences complete.
    *   Target: Start audio within ~500ms for short responses.

*   **UI (`UI/`):**
    *   `StatusBarController.swift`: Menu bar management and PTT button.
    *   `OverlayWindowController.swift`: Floating assistant overlay.
    *   `TranscriptView.swift`: User + assistant conversation display.
    *   `ToolExecutionView.swift`: Shows tool stages (Thinking → Proposing → Executing → Done).
    *   `ConfirmationDialog.swift`: Action confirmation UI.

*   **Orchestration:**
    *   `AssistantController.swift`: Central state machine coordinating all components.
    *   `Permissions.swift`: Manages Mic, Calendar, Reminders, Contacts, Accessibility.
    *   `AuditLog.swift`: Records all tool executions for transparency.

### Key Design Patterns

*   **Threading:**
    *   **Audio I/O:** Real-time thread (High priority, no locks).
    *   **ASR/LLM/TTS Inference:** Background actors (Swift Concurrency).
    *   **UI:** Main thread / MainActor.
*   **State Management:** `AssistantController` orchestrates all transitions.
*   **Tool Execution:** Always async, with confirmation gates for mutations.
*   **Streaming:** AsyncSequence-based pipelines for responsiveness.

---

## 4. Directory Structure

```text
Ora/
├── Ora/                    # Main App Source
│   ├── Audio/              # Capture, VAD, Buffers
│   ├── ASR/                # Parakeet engine, transcription
│   ├── LLM/                # Local LLM, tool calling, context
│   ├── Tools/              # Calendar, Reminders, Contacts, System
│   ├── TTS/                # Text-to-speech engine
│   ├── UI/                 # Overlay, Menu, Dialogs
│   ├── Orchestration/      # AssistantController, Permissions, AuditLog
│   ├── Utilities/          # Helpers
│   ├── main.swift          # Entry point
│   └── ...
├── OraTests/               # Unit Tests
├── Vendor/                 # External engines (Parakeet, llama.cpp, TTS)
├── docs/                   # Documentation
├── scripts/                # Build/Sign scripts
├── project.yml             # XcodeGen configuration
└── build.sh                # Build helper script
```

---

## 5. Tool Implementation Guidelines

### Guardrails Pattern (MANDATORY)

All tools that modify state **must** implement the confirmation pattern:

```swift
protocol Tool {
    var requiresConfirmation: Bool { get }
    func preview(parameters: ToolParameters) async throws -> ToolPreview
    func execute(parameters: ToolParameters) async throws -> ToolResult
}
```

**Confirmation required for:**
- Create event/reminder
- Delete event/reminder
- Send email (if implemented)

**No confirmation needed for:**
- Query calendar
- Search contacts
- List reminders
- Open app/URL

### Scope Minimization

- Fetch only what's needed (don't load entire contact database for a single search)
- Time-bound calendar queries (don't fetch years of history)
- Return minimal data to LLM context

### Audit Logging

Every tool execution must be logged:
```swift
AuditLog.record(
    tool: "calendar.create",
    parameters: [...],
    result: .success(eventId: "..."),
    timestamp: Date(),
    userConfirmed: true
)
```

---

## 6. Performance Targets

| Metric | Target |
|:-------|:-------|
| ASR partials | Every 200-400ms |
| End-of-speech finalization | ≤300ms |
| LLM time-to-first-token | <400ms (after warmup) |
| TTS audio start | ~500ms for short responses |
| PTT release → first spoken audio | <1.0s median (after warmup) |

### Memory & Stability
- No memory growth over 30 minutes of use
- Graceful fallback: if TTS fails → show text; if LLM fails → dictation-only mode

---

## 7. v1 Core Use Cases

**Calendar:**
- "Schedule a 30-min meeting with Maddie next week"
- "What's my day look like tomorrow?"
- "Find a 45-min slot this afternoon"

**Reminders:**
- "Remind me to submit expenses on Monday"

**Contacts:**
- "What's Roland's phone number?"

**System:**
- "Open Spotify"
- "Search the web for ..." (opens browser)

---

## 8. UX Principles

1. **Push-to-talk first:** `⌥Space` hotkey (customizable) + menubar mic button (no always-listening by default)
2. **Streaming everywhere:** Live partial transcription, streaming LLM tokens, early TTS
3. **Predictability > Cleverness:** Explicit intent preview before actions
4. **Confirmation gates:** Always ask before state-changing operations
5. **Auditability:** Every action logged, accessible in Preferences
6. **Private Mode:** Toggle to disable voice output, show text only
7. **Model transparency:** User can view all models (LLM, ASR, TTS) in Preferences

---

## 9. Troubleshooting

| Issue | Solution |
|:------|:---------|
| **Permissions prompt keeps appearing** | Run `./build.sh reset-perms` then `./build.sh run` and re-grant. |
| **Calendar/Reminders access denied** | Check System Settings → Privacy & Security → Calendar/Reminders. |
| **Contacts access denied** | Check System Settings → Privacy & Security → Contacts. |
| **No audio input** | Check microphone permissions and input device selection. |
| **LLM not responding** | Check model is loaded; verify memory available for inference. |
| **TTS silent** | Check audio output device; verify TTS engine initialization. |
| **Xcode Project out of sync** | Run `xcodegen generate`. |

---

## 10. Non-Goals (v1)

- "Always listening" wake word by default
- Fully general "do anything on my Mac" automation
- Reading arbitrary Mail inbox locally
- Cloud-based features (local-first only)

---

## 11. Future Phases

**Phase 2:** Wake word (optional), better memory, mail via provider APIs
**Phase 3:** On-device embeddings for local search ("what did I promise last week?")

---

## 12. Documentation Index

For deeper details, refer to the `docs/` folder:
- `docs/stories/PRD.md`: Full product requirements document (target users, v1 features, UX principles, performance targets)
- `docs/stories/ARCHITECTURE.md`: Detailed system design (component diagram, agentic loop, audio pipeline, model runtime, Swift 6 protocols, security)
- `docs/SETUP.md`: Detailed environment setup
- `docs/TESTING.md`: Test strategy
- `docs/stories/`: Implementation stories
