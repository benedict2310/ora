# T.05 - TTS Interruption UX

**Epic:** TTS Integration
**Status:** ✅ Complete
**Priority:** P2 (Medium - UX polish)
**Estimated Effort:** 0.5 day
**Dependencies:** T.02 (Audio Playback)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Allow users to stop ongoing text-to-speech playback without closing the overlay, so they can immediately continue the conversation after long responses.

## 2. User Story

As a user, I want to interrupt voice output without dismissing the overlay, so I can respond quickly when the assistant's answer is too long.

## 3. Scope

### In Scope
- Add a stop-speaking prompt at the bottom of the overlay while TTS is playing.
- Prompt uses the same visual treatment as the follow-up prompt shown when conversation mode is disabled.
- Escape key stops TTS if speaking (does not close overlay).
- Stop action transitions to `awaitingFollowUp` and preserves conversation state.

### Out of Scope
- Auto-barge-in / always-on listening while speaking
- Echo cancellation or duplex audio handling
- Changes to LLM streaming behavior

## 4. UX Notes

- The stop prompt should be visible during `.speaking` activity.
- Tapping the prompt or pressing Escape interrupts TTS and keeps the overlay visible.
- Overlay should scroll to keep the prompt visible when it appears.

## 5. Architecture Alignment

**Primary components:**
- `Ora/Orchestration/SimplePipelineController.swift`
- `Ora/Overlay/OverlayWindowController.swift`
- `Ora/Overlay/OverlayView.swift`

**Flow:**
```
TTS speaking → user interrupts → interruptSpeech() → awaitingFollowUp
```

## 6. Acceptance Criteria

- [ ] While TTS is speaking, a stop prompt appears at the bottom of the overlay.
- [ ] Clicking the prompt stops TTS but keeps the overlay visible.
- [ ] Pressing Escape while speaking stops TTS (does not close overlay).
- [ ] The overlay scrolls to keep the stop prompt visible when it appears.
- [ ] After stopping, the overlay transitions to awaiting follow-up.

## 7. Implementation Notes

- Add a new notification (`speechStopRequested`) for UI → pipeline communication.
- Reuse the existing follow-up prompt styling for the stop prompt.
- Keep changes localized; no new dependencies.
