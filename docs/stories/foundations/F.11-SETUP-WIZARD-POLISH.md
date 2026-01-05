# F.11 - Setup Wizard Polish

**Epic:** Foundations
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2-3 days
**Dependencies:** F.04, F.09, O.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** `docs/references/liquid-glass-ui.md`, `docs/references/liquid-glass-chat-ui.md`, `docs/stories/foundations/F.11-mockups.html`

---

## 1. Objective

Redesign the setup wizard to:
1. **Explain WHY** users need to download models (transparency builds trust)
2. **Require explicit user action** to start downloads (large files = user consent)
3. **Show clear progress** during downloads (bytes, speed, time remaining)
4. **Update the "All Set" screen** to reflect Conversation Mode (not press-and-hold)
5. **Apply Liquid Glass design** for visual consistency with macOS Tahoe

## 2. User Story

As a new user, I want to understand why Ora needs to download AI models, actively choose to start the download, see clear progress, and learn how to use Conversation Mode so I feel confident using the app.

## 3. Scope

### In Scope

#### Download Explanation & Consent
- Add a **pre-download screen** explaining what models are and why they're needed
- Show model sizes clearly (e.g., "~3.6 GB total")
- Require user to click "Download Now" to start (no auto-download)
- Explain privacy benefit: "Models run locally = your data stays private"

#### Download Progress Polish
- Show current file name being downloaded
- Show bytes downloaded / total bytes with percentage
- Show download speed (MB/s)
- Show estimated time remaining
- Clear state transitions: Pending → Downloading → Verifying → Ready → Error
- **Proper progress bars** (no legacy spinners) - both overall and per-model
- Checkmark icon when model complete, pending circle when waiting
- Error icon with message when failed
- Cancel button to abort, Retry button on error

#### "All Set" Screen Update (Conversation Mode)
- **Simple and direct**: "Press ⌥Space and start talking"
- Show the hotkey prominently in a glass card
- One-liner: "Ora will listen, respond, and keep the conversation going"
- No lengthy tutorial steps - keep it minimal

#### Liquid Glass Design
- Apply `.glassEffect()` to cards/panels where appropriate
- Use `GlassEffectContainer` for grouped elements
- Follow the design principles from `liquid-glass-ui.md`
- Respect accessibility (Reduced Transparency fallback)

### Out of Scope

- Changes to actual download mechanism (F.09 handles that)
- Model selection UI (covered by Preferences)
- Parallel downloads (sequential is fine)
- Background download notifications
- Wake word setup (future feature)

## 4. Architecture Alignment

- `SetupCoordinator` manages setup flow state machine
- `SetupState` holds current step, download progress, and UI state
- `ModelManager` and `HuggingFaceDownloader` handle actual downloads
- Downloads publish progress via callback in `downloadRequiredModels`
- Setup views observe `@Published` properties and update UI reactively
- New step `modelExplanation` inserted between `permissions` and `download`
- Download only starts when user explicitly clicks "Download Now"

### Current Issues (Based on Analysis)
1. **No explanation** - Users don't know what models are or why they need them
2. **Auto-download** - Downloads start automatically without user consent
3. **Progress unclear** - Only shows percentage, not bytes/speed/ETA
4. **Ready screen outdated** - Shows "Press & Hold" but we now have Conversation Mode
5. **No Liquid Glass** - Uses old macOS styling

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Setup/Steps/ModelExplanationStepView.swift` - New step explaining models + download consent

### 5.2 Files to Modify

- `Ora/Setup/SetupState.swift` - Add `.modelExplanation` step, download stats (bytes, speed)
- `Ora/Setup/SetupCoordinator.swift` - Handle new step, remove auto-download, add download stats
- `Ora/Setup/SetupWindow.swift` - Apply Liquid Glass styling, add new step routing
- `Ora/Setup/Steps/DownloadStepView.swift` - Enhanced progress UI (bytes, speed, ETA)
- `Ora/Setup/Steps/ReadyStepView.swift` - Update for Conversation Mode flow
- `Ora/Setup/Steps/WelcomeStepView.swift` - Optional Liquid Glass polish
- `Ora/Models/ModelManager.swift` - Expose bytes/speed in progress callback (if needed)

### 5.3 Tests to Add

- `OraTests/Setup/SetupCoordinatorTests.swift` - Test new step transitions, download consent flow
- `OraTests/Setup/SetupStateTests.swift` - Test download stats calculations

### 5.4 Dependencies/Config

- None (no new packages)

## 6. Acceptance Criteria

### Model Explanation Step
- [ ] AC-1: New "Model Explanation" step appears after Permissions, before Download
- [ ] AC-2: Lists all 3 models with descriptions and individual sizes
- [ ] AC-3: Shows total download size (~3.6 GB)
- [ ] AC-4: Explains privacy benefit of local processing
- [ ] AC-5: "Download Now" button initiates download (not automatic)
- [ ] AC-6: "Maybe Later" postpones setup (same as current Later behavior)

### Download Progress
- [ ] AC-7: Shows bytes downloaded / total bytes (e.g., "1.7 GB of 3.6 GB")
- [ ] AC-8: Shows download speed (e.g., "12.3 MB/s")
- [ ] AC-9: Shows estimated time remaining (e.g., "~2 min left")
- [ ] AC-10: Shows per-model progress with clear state icons
- [ ] AC-11: Cancel button aborts download and returns to Model Explanation step
- [ ] AC-12: Error state shows retry button
- [ ] AC-13: "Continue" button only enabled when all models complete

### Ready Screen
- [ ] AC-14: Shows hotkey prominently (e.g., "⌥Space") in a glass card
- [ ] AC-15: Simple message: "Press [hotkey] and start talking"
- [ ] AC-16: Brief description of conversation mode behavior

### Liquid Glass
- [ ] AC-17: Info cards use `.glassEffect()` styling
- [ ] AC-18: Respects Reduced Transparency accessibility setting
- [ ] AC-19: Glass only on appropriate elements (not full backgrounds)

### Edge Cases
- [ ] AC-20: Slow network shows realistic progress (not stuck)
- [ ] AC-21: Network disconnect shows helpful error message
- [ ] AC-22: Disk space error detected and reported
- [ ] AC-23: Partial downloads can be retried
- [ ] AC-24: Already-downloaded models immediately show as 100% complete (fix race condition)

## 7. Verification Plan

### Automated Tests

- [ ] SetupState step transitions include new ModelExplanation step
- [ ] SetupCoordinator doesn't auto-download (waits for user action)
- [ ] Download stats (bytes, speed) calculated correctly

### Manual Tests

- [ ] Fresh install: See model explanation, click Download, watch progress
- [ ] Verify bytes/speed/ETA update smoothly during download
- [ ] Cancel mid-download: Returns to explanation step
- [ ] Network disconnect: Error message, retry works
- [ ] Complete setup: Ready screen shows Conversation Mode instructions
- [ ] Test with Reduced Transparency enabled

## 8. Performance / Reliability Considerations

- Progress updates throttled to ~10/second max (avoid UI lag)
- Speed calculation uses rolling average (avoid spiky display)
- ETA uses smoothed estimate (avoid jumping numbers)
- UI remains responsive during large downloads

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Progress events not firing | Verify HuggingFaceDownloader publishes correctly |
| UI updates too frequent | Throttle progress updates |
| Speed/ETA jumping around | Use rolling average, smoothed estimates |
| Stuck on network timeout | Add timeout handling with clear error |
| Glass effect performance | Test on older Macs, respect accessibility |

## 10. Open Questions

- [x] Should downloads auto-start? **No - require explicit user action**
- [x] What should Ready screen show? **Conversation Mode (tap → speak → pause)**
- [ ] Should we show per-file progress within each model? (Models have multiple files)
- [ ] Add "Download in background" option for experienced users?

---

## Detailed Design

### New Setup Flow

```
Welcome → Permissions → Model Explanation → Download → Ready
                              ↑
                         NEW STEP
```

### Model Explanation Step (New)

**Title:** "Ora Runs Locally"

**Content:**
```
🧠 Why Download AI Models?

Ora uses three AI models that run entirely on your Mac:

• Speech Recognition (Parakeet) — ~600 MB
  Converts your voice to text

• Language Model (Qwen 3) — ~2.5 GB  
  Understands requests and generates responses

• Text-to-Speech (Kokoro) — ~500 MB
  Speaks responses back to you

Total: ~3.6 GB

🔒 Your Privacy Benefit
Because these models run locally, your conversations 
never leave your Mac. No cloud. No data collection.

[Download Now]  [Maybe Later]
```

### Enhanced Download Progress

```
┌─────────────────────────────────────────────────────┐
│  Downloading Models                                  │
│                                                     │
│  ████████████░░░░░░░░░░░░░░  47%                   │
│  1.7 GB of 3.6 GB  •  12.3 MB/s  •  ~2 min left    │
│                                                     │
│  ┌─────────────────────────────────────────────────┐   │
│  │ ✓ Parakeet ASR          600 MB    Complete  │   │
│  │ ◐ Qwen 3 4B            1.1/2.5 GB  45%     │   │
│  │ ○ Kokoro TTS            500 MB    Pending   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                     │
│  [Cancel Download]                                  │
└─────────────────────────────────────────────────────┘
```

**States per model:**
- `○` Pending (gray circle)
- `◐` Downloading (spinner)
- `✓` Complete (green checkmark)
- `✗` Error (red X with retry)

### Updated "All Set" Screen

**Title:** "You're All Set!"

**Content:**
```
                    ✓ (success icon)
              
              You're All Set!

                   Press

            ┌─────────────────┐
            │    ⌥ Space      │  (glass card)
            └─────────────────┘

              and start talking

   Ora will listen, respond, and keep 
        the conversation going.

              [Get Started]
```

Simple, direct, no lengthy tutorial.

### Liquid Glass Application

**Where to apply glass:**
- Card backgrounds in each step (info panels, model list)
- Progress bar container
- Tutorial step cards on Ready screen

**Where NOT to apply glass:**
- Window chrome (already handled by system)
- Text content directly
- Full backgrounds

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
