# O.05 - Improved Hotkey Flow

**Epic:** Orchestration
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** O.01 (ASR-LLM Pipeline)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Improve the hotkey-triggered voice interaction flow to be more predictable and user-friendly. The current push-to-talk (PTT) model requires holding the hotkey while speaking, which can be awkward. The new flow uses a **tap-to-start, Enter-to-send** model that feels more natural for voice input.

Additionally, the overlay dismissal behavior needs refinement—currently clicking outside the overlay dismisses it, which can be frustrating when the user is reading a response.

Finally, enable **multi-turn conversations** by allowing users to continue speaking after the assistant responds, with two modes:
- **Default (Manual):** User presses Enter to start recording their follow-up
- **Auto-Listen (Power User):** Recording automatically starts after assistant responds

## 2. User Story

As a **user**, I want to **tap the hotkey once to open the overlay and start recording, then press Enter to submit my voice input** so that I can **interact with the assistant without holding down a key while speaking**.

As a **user**, I want to **dismiss the overlay only by pressing Escape or the hotkey again** so that I can **click elsewhere on my screen without accidentally closing the assistant**.

As a **user**, I want to **continue the conversation after the assistant responds** by pressing Enter to record a follow-up, so that I can **have multi-turn conversations without reopening the overlay**.

As a **power user**, I want to **enable auto-listen mode** so that the assistant **automatically starts listening after responding**, creating a seamless conversational experience.

## 3. Scope

### In Scope

- **Hotkey tap** opens overlay and immediately starts recording (no hold required)
- **Enter key** stops recording and submits transcript to LLM
- **Escape key** cancels the session, erases transcript, and closes overlay
- **Hotkey re-press** (while overlay is open) cancels the session and closes overlay
- Remove click-outside-to-dismiss behavior
- Remove auto-dismiss after response completes (user explicitly dismisses)
- **Multi-turn conversation support:**
  - After response completes, show prompt: "Press Enter to reply, Escape to close"
  - Enter in `.completed` state starts recording again (same conversation context)
  - New state: `.awaitingFollowUp` between response and next recording
- **Auto-Listen setting:**
  - Menu bar toggle: "Auto-Listen After Response"
  - When enabled, automatically start recording after LLM response completes
  - Stored in UserDefaults/AppSettings

### Out of Scope

- Wake word / always-listening mode
- Voice activity detection (VAD) for auto-submit (future enhancement)
- TTS integration (separate epic)
- Changes to the hotkey configuration UI

## 4. Architecture Alignment

### Component Boundaries

| Component | Change |
|-----------|--------|
| **HotkeyManager** | No change (already posts press/release notifications) |
| **AppDelegate** | Update to only use `hotkeyDidPress` (ignore release) |
| **SimplePipelineController** | New `submitTranscript()` method; new `.awaitingFollowUp` state; `startFollowUp()` method; auto-listen logic |
| **OverlayWindowController** | Remove `clickOutsideMonitor`; add Enter key handler with state-aware behavior; remove auto-dismiss |
| **OverlayView** | Show "Press Enter to reply, Escape to close" prompt in `.awaitingFollowUp` state |
| **StatusBarController** | Add "Auto-Listen After Response" menu item toggle |
| **AppSettings/UserDefaults** | Store `autoListenEnabled` preference |

### Concurrency Model

- All changes remain on `@MainActor`
- No new actors or background tasks needed

### State Machine Update

```
                                    ┌──────────────────────────────────────────────┐
                                    │                                              │
                                    ▼                                              │
idle ──(hotkey)──► listening ──(Enter)──► thinking ──► responding ──► awaitingFollowUp
  ▲                    │                                                    │
  │                 (Escape                                                 │
  │                or hotkey)                                               │
  │                    │                          ┌─────────────────────────┤
  │                    ▼                          │                         │
  │                  idle ◄───(Escape/hotkey)─────┤                         │
  │                                               │                         │
  │                                               │    (Enter or            │
  │                                               │     auto-listen)        │
  │                                               │                         │
  └───────────────────────────────────────────────┴─────────► listening ◄───┘
```

**Key states:**
1. `idle` - Overlay closed, no session
2. `listening` - Recording user speech
3. `thinking` - Processing transcript with LLM
4. `responding` - LLM streaming response
5. `awaitingFollowUp` - Response complete, waiting for user to continue or exit

**Key transitions:**
- Hotkey **tap** (not hold) starts listening
- **Enter** in `listening` → submits to LLM
- **Enter** in `awaitingFollowUp` → starts listening again
- **Escape or hotkey** from any state → closes overlay
- **Auto-listen enabled**: `responding` → `listening` automatically

### PRD/Architecture References

- [PRD.md](../PRD.md): UX Principles - "Push-to-talk first" → evolving to "Tap-to-talk"
- [ARCHITECTURE.md](../ARCHITECTURE.md): State machine patterns

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

None.

### 5.2 Files to Modify

- `Ora/AppDelegate.swift`
  - Remove `hotkeyReleaseObserver` and `onHotkeyRelease()` handler
  - Update `onHotkeyPress()` to toggle: if overlay visible → cancel, else → start

- `Ora/Orchestration/PipelineState.swift`
  - Add `.awaitingFollowUp` state
  - Update `canStartListening` to include `.awaitingFollowUp`

- `Ora/Orchestration/SimplePipelineController.swift`
  - Add `submitTranscript()` method that stops recording and triggers LLM processing
  - Add `startFollowUp()` method to start recording from `.awaitingFollowUp`
  - Modify `startListening()` to be a toggle (cancel if already active)
  - Remove reliance on `stopListening()` being called from hotkey release
  - Remove auto-dismiss task scheduling
  - Add auto-listen logic in `handleCompletion()`: if enabled, call `startFollowUp()` after short delay
  - Read auto-listen setting from AppSettings

- `Ora/Overlay/OverlayWindowController.swift`
  - Remove `clickOutsideMonitor` (global click monitor)
  - Update key handler for Enter with state-aware behavior:
    - `.listening` → `submitTranscript()`
    - `.awaitingFollowUp` → `startFollowUp()`
    - `.thinking`/`.responding` → ignore
  - Remove `scheduleAutoDismiss()` calls and `autoDismissTask`
  - Keep Escape key handler (already calls `cancel()`)

- `Ora/Overlay/OverlayView.swift`
  - Add prompt view for `.awaitingFollowUp` state: "Press Enter to reply, Escape to close"
  - Style consistently with existing status indicators

- `Ora/Overlay/OverlayState.swift`
  - Add `.awaitingFollowUp` to `OverlayMode` enum
  - Add status text for new state

- `Ora/UI/StatusBarController.swift`
  - Add "Auto-Listen After Response" menu item with checkmark toggle
  - Wire to AppSettings

- `Ora/Persistence/Models/AppSettings.swift`
  - Add `autoListenEnabled: Bool` property (default: `false`)

### 5.3 Tests to Add

- `OraTests/Orchestration/SimplePipelineControllerTests.swift`
  - `test_submitTranscript_fromListening_transitionsToThinking`
  - `test_submitTranscript_withEmptyTranscript_closesOverlay`
  - `test_handleCompletion_transitionsToAwaitingFollowUp`
  - `test_startFollowUp_fromAwaitingFollowUp_transitionsToListening`
  - `test_autoListen_whenEnabled_automaticallyStartsListening`
  - `test_cancel_fromAwaitingFollowUp_closesOverlay`

- `OraTests/Orchestration/PipelineStateTests.swift`
  - `test_awaitingFollowUp_canStartListening`

### 5.4 Dependencies/Config

None.

## 6. Acceptance Criteria

### Hotkey Behavior

- [ ] AC-1: Pressing hotkey when overlay is closed opens overlay and starts recording
- [ ] AC-2: Pressing hotkey when overlay is open cancels session and closes overlay
- [ ] AC-3: Releasing the hotkey does NOT stop recording or submit transcript

### Enter Key Behavior

- [ ] AC-4: Pressing Enter while in `.listening` state stops recording and submits to LLM
- [ ] AC-5: Pressing Enter while in `.thinking` or `.responding` state is ignored (no action)
- [ ] AC-6: Pressing Enter while in `.awaitingFollowUp` state starts recording for follow-up

### Escape Key Behavior

- [ ] AC-7: Pressing Escape from any state cancels session and closes overlay
- [ ] AC-8: Escape works during listening, thinking, responding, and awaitingFollowUp states
- [ ] AC-9: Pressing Escape during recording erases the current transcript text before closing

### Dismissal Behavior

- [ ] AC-10: Clicking outside the overlay does NOT close it
- [ ] AC-11: Overlay remains visible after response completes (shows awaitingFollowUp state)
- [ ] AC-12: Overlay can only be dismissed via Escape key or hotkey re-press

### State Transitions

- [ ] AC-13: Empty transcript (no speech) shows prompt without calling LLM when Enter is pressed
- [ ] AC-14: State transitions: idle → listening → thinking → responding → awaitingFollowUp
- [ ] AC-15: From awaitingFollowUp, Enter → listening (preserves conversation context)

### Multi-Turn Conversation

- [ ] AC-16: After response completes, overlay shows "Press Enter to reply, Escape to close"
- [ ] AC-17: Pressing Enter in awaitingFollowUp starts a new recording (same session)
- [ ] AC-18: Conversation context (history) is preserved across turns within a session
- [ ] AC-19: Closing overlay (Escape/hotkey) ends the session and clears context

### Auto-Listen Setting

- [ ] AC-20: Menu bar contains "Auto-Listen After Response" toggle item
- [ ] AC-21: Toggle shows checkmark when enabled
- [ ] AC-22: Setting persists across app restarts
- [ ] AC-23: When enabled, recording starts automatically after response completes
- [ ] AC-24: When disabled (default), user must press Enter to start follow-up recording

## 7. Verification Plan

### Automated Tests

- [ ] `test_submitTranscript_fromListening_transitionsToThinking`
- [ ] `test_submitTranscript_withEmptyTranscript_closesOverlay`
- [ ] `test_handleCompletion_transitionsToAwaitingFollowUp`
- [ ] `test_startFollowUp_fromAwaitingFollowUp_transitionsToListening`
- [ ] `test_autoListen_whenEnabled_automaticallyStartsListening`
- [ ] `test_cancel_fromAnyState_returnsToIdle`

### Manual Tests

- [ ] Tap hotkey → overlay opens, starts recording (mic icon visible)
- [ ] Speak something, press Enter → transcript submitted, LLM responds
- [ ] Response completes → shows "Press Enter to reply, Escape to close"
- [ ] Press Enter → recording starts again, can speak follow-up
- [ ] While response is shown, click outside overlay → overlay stays visible
- [ ] Press Escape → overlay closes, session ends
- [ ] Tap hotkey, speak, tap hotkey again → overlay closes (cancel)
- [ ] Tap hotkey, say nothing, press Enter → shows prompt without LLM call
- [ ] Enable auto-listen in menu → after response, recording starts automatically
- [ ] Disable auto-listen → must press Enter to continue
- [ ] Quit and relaunch → auto-listen setting persists

## 8. Performance / Reliability Considerations

- No performance impact expected; this is purely UX/flow changes
- Removing auto-dismiss timer simplifies state management
- Removing click-outside monitor reduces event handling overhead
- Auto-listen delay (~500ms) prevents jarring transition and gives user time to process response

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Users accustomed to PTT may be confused | Hotkey re-press still works as "cancel", similar to toggling |
| Overlay persisting may be annoying | User has explicit control; can always Escape |
| Enter key conflict with other apps | Overlay is a floating panel that captures key events when visible |
| Auto-listen may surprise users | Disabled by default; explicit opt-in via menu |
| Auto-listen may record unintended speech | User can press Escape immediately; short delay before recording |

## 10. Open Questions

None - requirements are clear.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
