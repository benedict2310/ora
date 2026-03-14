# I.01 - Text Input Mode

**Epic:** Input
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3-4 days
**Dependencies:** O.07, V.03
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Let users type messages instead of speaking, so Ora can be used silently (in meetings, libraries, late at night) without changing the activation flow. The voice-first experience stays default — typing is a seamless fallback discovered through a status pill hint.

## 2. User Story

As a user, I want to start typing after pressing the hotkey so that I can interact with Ora silently without changing my workflow.

## 3. Scope

### In Scope

- Detect printable key presses while in `.listening` mode and switch to text input mode.
- On mode switch: stop audio capture, discard any ASR partials, show a single-line text field.
- Submit the typed message with Enter. Route it through the existing `AgentLoop.process(userText:imageAttachments:)` path.
- Keep audio disabled for the remainder of the conversation after switching to text mode.
- Show a re-enable shortcut hint in the status pill: "Type a message or ⌘D for voice".
- ⌘D re-enables voice mode and immediately starts listening.
- Status pill progression:
  1. "Listening..." (normal voice mode, active recording indicator)
  2. "Start typing..." (after 3 seconds of silence, passive hint)
  3. User types → text field replaces the status pill
  4. After submission: "Type a message or ⌘D for voice" (while awaiting follow-up)
- Image attachments (V.03) continue to work alongside text input.
- Escape closes the overlay / cancels input (existing behavior preserved).

### Out of Scope

- Pre-filling ASR partial text into the text field when switching modes (follow-up story I.02).
- Multi-line text input (Shift+Enter for newlines).
- Always-visible text field (text field only appears on first keystroke).
- Changing the activation hotkey or adding a dedicated text-only hotkey.
- Rich text, markdown rendering, or inline code editing in the input field.

## 4. Architecture Alignment

- **Pipeline boundaries preserved:** Text input produces a `String` that enters the same `AgentLoop.process(userText:imageAttachments:)` path as ASR. No changes to LLM, Tools, or TTS layers.
- **State machine:** `SimplePipelineController` gains an `InputMode` enum (`.voice`, `.text`) tracked per session. The mode influences whether `runListeningSession()` starts audio capture or shows the text field.
- **Key event handling:** The existing `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` (macOS 10.6+) in `OverlayWindowController` (line 268) is the interception point for detecting printable keystrokes during `.listening` mode. Use `event.characters` to distinguish printable characters from function keys (unicode range 0xF700–0xF8FF) and modifier-only presses. Filter out Escape (keyCode 53), Enter (keyCode 36), and ⌘-modified keys before triggering the mode switch.
- **Concurrency:** Text field is `@MainActor` SwiftUI. Audio teardown uses existing `AudioService.stop()` on a background actor — no new threading concerns.
- **Silence timer:** A 3-second timer after entering `.listening` mode triggers the "Start typing..." hint. This is distinct from the existing silence detector (which handles auto-submit of ASR). The hint timer is cancelled if the user speaks (VAD fires) or types.
- **Session lifecycle:** `InputMode` resets to `.voice` on `cancel()` and `reset()`. Switching to text mode mid-session is one-way until ⌘D.
- **OverlayViewModel:** Gains `inputMode` and `typingHintVisible` published properties. The `VoiceInputControlView` reads these to decide between its current voice UI and the new text field.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Overlay/TextInputView.swift` — Single-line text field with Enter-to-submit, styled to match the voice input pill (same glass background, same max width). Prefer SwiftUI `TextField` with `.onSubmit {}` (macOS 12+) and `@FocusState` for first-responder management. Fall back to `NSTextField` (NSViewRepresentable) only if SwiftUI focus handling proves unreliable for the initial keystroke forwarding.

### 5.2 Files to Modify

- `Ora/Orchestration/SimplePipelineController.swift`
  - Add `InputMode` enum (`.voice`, `.text`) and `inputMode` property.
  - Add `switchToTextInput()`: stops audio, cancels ASR, sets mode, updates overlay.
  - Add `submitTextInput(_:)`: routes typed text through `processTranscript()` equivalent.
  - Add `reEnableVoiceInput()`: resets to `.voice`, starts listening.
  - Add 3-second silence hint timer in `runListeningSession()`.
- `Ora/Orchestration/SimplePipelineController+Session.swift`
  - Respect `inputMode` — skip audio capture in `.text` mode during follow-up turns.
- `Ora/Orchestration/SimplePipelineController+Agent.swift`
  - Add `processTextInput(_ text: String)` mirroring `processTranscript()`.
- `Ora/Overlay/OverlayWindowController.swift`
  - Extend the `.keyDown` monitor (line 268): detect printable characters during `.listening` mode and call `switchToTextInput()`, forwarding the first character to the text field.
  - Add ⌘D shortcut to call `reEnableVoiceInput()`.
- `Ora/Overlay/OverlayState.swift`
  - Add `inputMode: InputMode` to `OverlayViewModel`.
  - Add `typingHintVisible: Bool` to `OverlayViewModel`.
  - Add `textInputText: String` binding for the text field content.
- `Ora/Overlay/OverlayView.swift`
  - Replace `VoiceInputControlView` with conditional: show `TextInputView` when `inputMode == .text`, else show `VoiceInputControlView`.
- `Ora/Overlay/VoiceInputControlView.swift`
  - Add a new `.State` case or modify `.idle` to support the "Start typing..." hint text.
  - Show the typing hint after the silence timer fires (driven by `typingHintVisible`).
  - Show "Type a message or ⌘D for voice" in `.awaitingFollowUp` when `inputMode == .text`.

### 5.3 Tests to Add

- `OraTests/Orchestration/TextInputModeTests.swift`
  - Test: printable keystroke during `.listening` switches `inputMode` to `.text`.
  - Test: `switchToTextInput()` stops audio service and cancels ASR.
  - Test: `submitTextInput()` calls `agentLoop.process(userText:)` with the typed text.
  - Test: `reEnableVoiceInput()` resets `inputMode` to `.voice` and starts listening.
  - Test: `inputMode` resets to `.voice` on `cancel()` and `reset()`.
  - Test: 3-second silence timer sets `typingHintVisible` (and cancels on VAD/typing).
  - Test: image attachments are included when submitting text input.
- `OraTests/Overlay/TextInputViewTests.swift`
  - Test: Enter key submits text and clears the field.
  - Test: Empty text is not submitted.
  - Test: Escape dismisses (existing behavior).

### 5.4 Dependencies/Config

- No new dependencies. Uses `NSTextField` (AppKit) wrapped for SwiftUI.
- No `project.yml` changes needed.

## 6. Acceptance Criteria

- [ ] AC-1: Pressing a printable key while in `.listening` mode stops audio capture and shows a text field with the typed character.
- [ ] AC-2: Enter submits the text field content through `AgentLoop.process(userText:imageAttachments:)`.
- [ ] AC-3: Audio capture remains disabled for subsequent turns in the same session after switching to text mode.
- [ ] AC-4: ⌘D re-enables voice mode and starts listening immediately.
- [ ] AC-5: The status pill shows "Start typing..." after 3 seconds of silence in voice mode.
- [ ] AC-6: The status pill shows "Type a message or ⌘D for voice" when awaiting follow-up in text mode.
- [ ] AC-7: Image attachments (paste/file/screenshot) work alongside text input.
- [ ] AC-8: Escape closes the overlay / cancels the session regardless of input mode.
- [ ] AC-9: `inputMode` resets to `.voice` when a new session starts.

## 7. Verification Plan

### Automated Tests

- [ ] `./build.sh test`
- [ ] `TextInputModeTests` — mode switching, audio teardown, text submission, ⌘D re-enable, timer, reset.
- [ ] `TextInputViewTests` — Enter submit, empty guard, Escape passthrough.

### Manual Tests

- [ ] Press hotkey, wait 3 seconds, verify "Start typing..." hint appears.
- [ ] Press hotkey, start typing, verify audio stops and text field appears with first character.
- [ ] Type a message, press Enter, verify assistant responds (same as voice flow).
- [ ] After text submission, verify follow-up turn stays in text mode (no audio).
- [ ] Press ⌘D during text mode, verify mic activates and "Listening..." returns.
- [ ] Press hotkey, speak immediately (before 3s), verify normal voice flow (no hint shown).
- [ ] Paste an image, then type a question about it, verify both are sent.
- [ ] Press Escape during text input, verify overlay closes.

## 8. Performance / Reliability Considerations

- Audio teardown on mode switch should be fast (<50ms) to avoid perceived lag between typing and text field appearing.
- The 3-second silence hint timer must not interfere with the existing silence detector (auto-submit). They serve different purposes: hint timer is purely UI, silence detector triggers ASR submission.
- Text field must become first responder immediately on mode switch so keystrokes aren't lost.
- The first typed character must appear in the text field (not be swallowed by the mode switch).

## 9. Risks & Mitigations

- **First responder race:** NSTextField may not become first responder instantly, causing the first character to be lost.
  - Mitigation: Forward the triggering keystroke's character to the text field programmatically after mode switch.

- **Conflict with existing keyboard shortcuts:** Other key monitors (Escape, Enter, proposal confirmation) must not interfere with normal typing.
  - Mitigation: When `inputMode == .text` and the text field has focus, let the text field handle all non-shortcut keys. Only intercept ⌘D, Escape, and Enter.

- **⌘D conflicts with macOS system dictation:** macOS uses ⌘⌘ (double-press Command) or Fn for dictation, not ⌘D. No conflict expected, but verify during manual testing.

## 10. Open Questions

- Should the text field have a character limit? Voice input is naturally limited by speech duration, but typed input has no inherent bound. The LLM context window (32K tokens) provides an implicit limit, but a UI hint might be needed for very long inputs.

---

## Implementation Summary

**Date:** 2026-03-14
**Branch:** `feat/I.01-text-input-mode`
**Commits:** 3
**Implemented by:** codex (complexity score: 9/10)
**Reviewed by:** orchestrator (1 iteration)

### Files Changed
- `Ora/Orchestration/SimplePipelineController.swift` - Modified: added InputMode enum, switchToTextInput(), submitTextInput(), reEnableVoiceInput(), typing hint timer
- `Ora/Orchestration/SimplePipelineController+Session.swift` - Modified: guard audio capture on inputMode, start typing hint timer, cancel hint on VAD
- `Ora/Orchestration/SimplePipelineController+Agent.swift` - Modified: unified processUserInput() for voice and text paths
- `Ora/Orchestration/SimplePipelineController+Speech.swift` - Modified: text mode awareness in speech completion follow-up
- `Ora/Overlay/OverlayState.swift` - Modified: added inputMode, typingHintVisible, textInputText, isTextInputVisible to OverlayViewModel
- `Ora/Overlay/OverlayView.swift` - Modified: conditional TextInputView/VoiceInputControlView, status pill hints
- `Ora/Overlay/OverlayWindowController.swift` - Modified: printable key detection, ⌘D shortcut, text mode key routing
- `Ora/Overlay/TextInputView.swift` - Created: single-line text field with glass styling and Enter-to-submit
- `OraTests/Orchestration/TextInputModeTests.swift` - Created: 6 tests covering mode switch, submit, follow-up, re-enable, cancel/reset, timer
- `OraTests/Orchestration/MockPipelineDependencies.swift` - Modified: added MockASRService and accessor methods
- `OraTests/Overlay/TextInputViewTests.swift` - Created: 3 tests for submit, empty guard, escape
- `OraTests/Overlay/OverlayWindowTests.swift` - Modified: 2 tests for printable key detection and ⌘D shortcut

## Code Review Findings

**Reviewer:** Orchestrator
**Date:** 2026-03-14
**Iteration:** 1

### Summary
- Files reviewed: 12
- Build status: Pass
- Tests: 1609/1610 passed (1 pre-existing unrelated failure)

### Issues Found

#### P0 - Critical (Must fix)
- [x] None.

#### P1 - Major (Should fix)
- [x] None.

#### P2 - Minor (Can defer)
- [x] None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
