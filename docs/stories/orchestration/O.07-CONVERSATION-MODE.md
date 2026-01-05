# O.07 - Conversation Mode

**Epic:** Orchestration
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** O.03, O.05, A.02
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Add automatic silence detection so users don't have to manually submit their message. When the user stops speaking, Ora automatically processes the transcript after a brief pause. Rename "Auto-listen after response" to "Conversation Mode" and make it the default, creating a natural back-and-forth conversation flow.

## 2. User Story

As a user, I want Ora to automatically know when I'm done speaking so that I don't have to press a key to submit my message - just talk naturally.

## 3. Scope

### In Scope

- **Silence Detection**: Detect end-of-speech and auto-submit after configurable pause (e.g., 1.5s)
- **Conversation Mode**: Combine silence detection + auto-listen into unified "Conversation Mode"
- **Default Behavior**: Make Conversation Mode the default (can be disabled in Preferences)
- **Visual Feedback**: Show silence detection countdown in UI (optional - subtle indicator)
- **Interrupt Handling**: Allow user to interrupt during TTS playback to ask follow-up

### Out of Scope

- Wake word detection ("Hey Ora")
- Voice Activity Detection improvements (use existing VAD in ASR)
- Changes to ASR engine (Parakeet)
- Push-to-talk mode removal (keep as alternative)

## 4. Architecture Alignment

- **ASR Service**: Already has partial/final events - can use timing between partials to detect silence
- **SimplePipelineController**: Add silence timer that triggers submit after pause
- **Settings**: Rename `autoListenEnabled` to `conversationModeEnabled`, default `true`
- **PipelineState**: May need transitional state like `.detectingSilence` or reuse `.listening`

### Silence Detection Strategy

Option A: **ASR-based** (Recommended)
- Track time since last ASR partial update
- If no new partials for X seconds AND we have transcript text → auto-submit
- Leverage ASR's built-in silence detection if available

Option B: **Audio-level based**
- Monitor audio input levels from AudioService
- If levels below threshold for X seconds → auto-submit
- More complex, may conflict with ASR

**Recommendation**: Use Option A - simpler, uses existing ASR timing.

### Conversation Mode Flow

```
User presses hotkey → .listening
    ↓
User speaks → ASR partials update transcript
    ↓
User stops speaking → silence detected (1.5s timeout)
    ↓
Auto-submit → .thinking → LLM → .responding → .speaking (TTS)
    ↓
TTS completes → .listening (auto-start recording for next turn)
    ↓
(repeat until user presses hotkey to end or says "goodbye")
```

## 5. Implementation Plan

### 5.1 Files to Create

- `Ora/Orchestration/SilenceDetector.swift` - Monitors ASR partial timing and detects end-of-speech

### 5.2 Files to Modify

- `Ora/Orchestration/SimplePipelineController.swift` - Integrate SilenceDetector, auto-submit on timeout
- `Ora/Persistence/Models/AppSettings.swift` - Rename `autoListenEnabled` → `conversationModeEnabled`, default `true`
- `Ora/Preferences/Tabs/GeneralPreferencesView.swift` - Add "Conversation Mode" toggle
- `Ora/UI/StatusBarController.swift` - Rename menu item to "Conversation Mode"

### 5.3 Tests to Add

- `OraTests/Orchestration/SilenceDetectorTests.swift` - Timeout triggers, reset on partial, cancellation

### 5.4 Implementation Details

#### SilenceDetector Design
```swift
@MainActor
final class SilenceDetector {
    // Configurable timeout (default 1.5s)
    private let timeout: TimeInterval
    private var silenceTask: Task<Void, Never>?
    private var hasReceivedPartial = false

    // Called when ASR partial received - resets timer
    func onPartialReceived()

    // Called when silence timeout fires
    var onSilenceDetected: (() -> Void)?

    // Cancel any pending timer
    func cancel()

    // Reset state for new session
    func reset()
}
```

#### Integration Flow
1. When `conversationModeEnabled` and state is `.listening`:
   - Create SilenceDetector with configured timeout
   - On each `.partial` ASR event: call `onPartialReceived()`
   - When `onSilenceDetected` fires: auto-submit (same as Enter key)
2. Manual submit (Enter) cancels the silence timer
3. Cancel operation cancels the silence timer

#### Migration Strategy
Use `@Attribute(originalName: "autoListenEnabled")` to preserve existing user settings while renaming the property to `conversationModeEnabled`.

### 5.5 Dependencies/Config

- Silence timeout constant: 1.5 seconds (could be made configurable later)

## 6. Acceptance Criteria

### Silence Detection
- [ ] AC-1: After user stops speaking for 1.5s (configurable), transcript auto-submits
- [ ] AC-2: Silence timer only starts after receiving at least one ASR partial
- [ ] AC-3: Silence timer resets on each new ASR partial
- [ ] AC-4: Empty transcripts don't trigger auto-submit

### Conversation Mode
- [ ] AC-5: "Auto-listen after response" renamed to "Conversation Mode" in Preferences
- [ ] AC-6: Conversation Mode is enabled by default for new installs
- [ ] AC-7: When enabled: silence detection + auto-listen both active
- [ ] AC-8: When disabled: user must press Enter to submit, no auto-listen

### User Experience
- [ ] AC-9: User can still press Enter to submit early (before silence timeout)
- [ ] AC-10: User can press hotkey during conversation to end/cancel
- [ ] AC-11: Conversation continues naturally through multiple turns without key presses
- [ ] AC-12: Optional: Visual indicator shows "listening..." state clearly

### Edge Cases
- [ ] AC-13: Very short utterances ("yes", "no") still detected and submitted
- [ ] AC-14: Long pauses mid-sentence (thinking) handled gracefully - may need longer timeout
- [ ] AC-15: Rapid back-and-forth conversation works without race conditions

## 7. Verification Plan

### Automated Tests

- [ ] SilenceDetector timeout triggers after configured duration
- [ ] SilenceDetector resets on new partial
- [ ] SimplePipelineController auto-submits on silence timeout

### Manual Tests

- [ ] Enable Conversation Mode, press hotkey, speak, stop → auto-submits
- [ ] Speak a long sentence with pauses → doesn't submit mid-sentence (timeout is per-partial)
- [ ] Say "yes" briefly → still detected and submitted
- [ ] After response, immediately speak again → conversation continues
- [ ] Disable Conversation Mode → must press Enter to submit

## 8. Performance / Reliability Considerations

- Silence timeout should be configurable (default 1.5s, range 0.5s - 3s)
- Timer must be cancelled on manual submit or cancel
- No audio processing overhead - just track ASR event timing

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Submits too early during pauses | Make timeout configurable, start with 1.5s |
| Submits too late, feels slow | Add visual countdown so user knows it's coming |
| Race condition with manual submit | Ensure only one submit path executes |
| Confusing when combined with TTS | Clear state transitions, visual feedback |

## 10. Open Questions

- [ ] What's the ideal default silence timeout? (1.5s proposed)
1.5 sec is fine, but make it configurable.
- [ ] Should we show a visual countdown during silence detection?
No, but let's leave that decision for manual testing.
- [ ] Should Conversation Mode require re-pressing hotkey to start, or persist until explicit cancel?
No.
- [ ] How to handle "goodbye" / explicit end of conversation?
Not a at all at the moment. We end the conversation with esc/click outside the window/2nd press of hotkey.
---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
