# BUG-006: Microphone Permission Dialog Breaks Overlay Focus

**Status:** Complete
**Priority:** P1 (Critical - First-run UX broken)
**Created:** 2026-01-14
**Last Updated:** 2026-01-14
**Fixed:** 2026-01-14

---

## 1. Problem Statement

When the microphone permission dialog appears on first use (after pressing the hotkey), the overlay window disappears and doesn't come back, even though the audio pipeline continues to work (microphone captures audio, LLM processes it).

**User-visible behavior:**
- Press hotkey → overlay briefly appears
- Microphone permission dialog appears (first time only)
- User grants permission
- Permission dialog dismisses
- Overlay is NOT visible, but audio is being captured and LLM responds

**Expected behavior:**
- Overlay should remain visible (or restore) after permission dialog dismisses

---

## 2. Root Cause Analysis

### 2.1 Original Hypothesis: Session Cancellation (INCORRECT)

Initially suspected that `handleAppDeactivated()` was cancelling the session because `PermissionPromptTracker.shared.isPromptActive` was `false`.

### 2.2 Actual Root Cause: Race Condition (CONFIRMED)

Debug logging revealed a **race condition**:

```
[10:24:09Z] endPrompt called for: microphone, current prompts: []
[10:24:09Z] handleAppDeactivated - isVisible: true, isPromptActive: false  ← PROBLEM
[10:24:09Z] handleAppDeactivated - CANCELLING SESSION
[10:24:10Z] beginPrompt called for: microphone  ← TOO LATE!
```

The permission dialog appears **BEFORE** `PermissionPromptTracker.beginPrompt()` is called.

**Why this happens:**
1. `SimplePipelineController.startListening()` shows the overlay
2. Starts a Task that calls `AudioService.start()`
3. `AudioService.start()` calls `PermissionsManager.request(.microphone)`
4. `PermissionsManager.request()` calls `beginPrompt()` then `client.request()`
5. BUT: The system shows the permission dialog **before** `beginPrompt()` executes on MainActor

The async/await scheduling means `beginPrompt()` (which runs on MainActor) may not execute before the system eagerly shows the permission dialog.

### 2.3 Fix Applied: Pre-emptive Tracking

Added pre-emptive tracking in `SimplePipelineController.runListeningSession()`:

```swift
// Pre-emptively track permission prompt if microphone permission is not determined
let micStatus = await PermissionsManager.shared.check(.microphone)
let needsMicPermission = micStatus == .notDetermined
if needsMicPermission {
    await PermissionPromptTracker.shared.beginPrompt(for: .microphone)
}

// Start audio capture (may trigger permission dialog)
let audioStream = try await AudioService.shared.start()

// Clean up pre-emptive tracker
if needsMicPermission {
    await PermissionPromptTracker.shared.endPrompt(for: .microphone)
}
```

This ensures `beginPrompt()` is called **before** any code that might trigger the permission dialog.

### 2.4 Second Issue: Window Ordering After Dialog Dismisses (FIXED)

After fixing the race condition, debug logs showed the session was no longer being cancelled, but the overlay still wasn't visible:

```
[19:00:08Z] handlePermissionPromptEnded called - isSessionActive: true
[19:00:08Z] show() completed - isVisible=true, alpha=1.0, isKeyWindow=false  ← PROBLEM
```

**Root cause:** When the permission dialog dismisses, the window system doesn't properly return focus to our app. The panel reports `isVisible=true` but is actually behind other windows. `makeKeyAndOrderFront` fails because the app isn't properly active (`isKeyWindow=false`).

### 2.5 Final Fix: Delayed Restoration with Window Level Bump

Added `restoreAfterExternalDialog()` method in `OverlayWindowController.swift`:

1. **Delay before restoration:** Wait 100ms for window system to settle after permission dialog dismisses
2. **Activate app first:** Call `NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])`
3. **Temporarily bump window level:** Set to `.popUpMenu` (higher than system dialogs)
4. **Force window ordering:** `orderFrontRegardless()` + `makeKeyAndOrderFront(nil)`
5. **Restore original level:** After 50ms, restore to `.floating`

After the fix:
```
[19:00:08Z] restoreAfterExternalDialog - isAppActive: false, panelVisible: true
[19:00:08Z] restoreAfterExternalDialog - restored level, isKeyWindow: true  ← SUCCESS
```

---

## 3. Current Investigation Status

### 3.1 What's Working
- Pre-emptive tracking prevents session cancellation
- `handleAppDeactivated()` correctly detects permission prompt is active
- `handleAppDeactivated()` does NOT cancel the session
- Audio capture works after permission granted
- LLM processing works

### 3.2 What's Still Broken
- Overlay window is not visible after permission dialog dismisses
- User cannot see the UI even though the pipeline is working

### 3.3 Suspected Issues (To Investigate)

1. **`handlePermissionPromptEnded()` not being called or not working:**
   - This method should call `show()` to restore the overlay
   - Need to verify it's being triggered

2. **Window ordering issue:**
   - The panel might be "visible" but behind other windows
   - `orderFrontRegardless()` and `NSApp.activate()` were added but may not be sufficient

3. **Panel state issue:**
   - Panel might be in a weird state (alpha=0, off-screen, etc.)
   - First-time panel creation + immediate focus loss might cause issues

4. **Notification timing:**
   - `.permissionPromptDidEnd` notification might not trigger overlay restoration correctly

---

## 4. Files Modified

| File | Changes |
|:-----|:--------|
| `Ora/Orchestration/SimplePipelineController.swift` | Added pre-emptive permission tracking before `AudioService.start()` |
| `Ora/Overlay/OverlayWindowController.swift` | Added `orderFrontRegardless()`, debug logging, `debugLog()` helper |
| `Ora/Permissions/PermissionPromptTracker.swift` | Added debug logging to `beginPrompt()`/`endPrompt()` |
| `Ora/Permissions/MicrophonePermission.swift` | Removed duplicate tracker calls (handled by PermissionsManager) |
| `Ora/Permissions/EventKitPermission.swift` | Removed duplicate tracker calls |
| `Ora/Permissions/ContactsPermission.swift` | Removed duplicate tracker calls |
| `AGENTS.md` | Updated permission tracking documentation |
| `docs/stories/ARCHITECTURE.md` | Added Focus Recovery section with correct architecture |

---

## 5. Key Code Locations

### Permission Tracking Architecture

```
PermissionsManager.request()     ← Central tracking (beginPrompt/endPrompt)
    └── calls individual permission files (NO tracking here)
        ├── MicrophonePermission.request()
        ├── EventKitPermission.requestCalendar()
        └── ContactsPermission.request()

SimplePipelineController.runListeningSession()  ← Pre-emptive tracking for race condition
    └── beginPrompt() BEFORE AudioService.start()

Tool-level providers (separate tracking for direct tool access):
    ├── EventStoreProvider.ensureCalendarAccess()
    └── RemindersStoreProvider.ensureRemindersAccess()
```

### Overlay Focus Recovery

```
OverlayWindowController:
    - handleAppDeactivated()      ← Checks isPromptActive, cancels if false
    - handlePermissionPromptEnded() ← Should restore overlay via show()
    - handleAppActivated()        ← Backup restoration on app activation
    - show()                      ← orderFrontRegardless + makeKeyAndOrderFront + NSApp.activate
```

---

## 6. Debug Logging

Debug logs are written to `/tmp/ora-overlay-debug.log` for:
- `PermissionPromptTracker.beginPrompt()` / `endPrompt()`
- `OverlayWindowController.handleAppDeactivated()`

**To view logs:**
```bash
cat /tmp/ora-overlay-debug.log
```

**To clear and test:**
```bash
rm /tmp/ora-overlay-debug.log
./build.sh reset-perms
./build.sh run
# Press hotkey, grant permission
cat /tmp/ora-overlay-debug.log
```

---

## 7. Next Steps

### 7.1 Immediate Investigation

1. **Add logging to `handlePermissionPromptEnded()`:**
   ```swift
   private func handlePermissionPromptEnded() {
       Self.debugLog("handlePermissionPromptEnded called - isSessionActive: \(SimplePipelineController.shared.isSessionActive)")
       guard SimplePipelineController.shared.isSessionActive else {
           Self.debugLog("handlePermissionPromptEnded - early return: session not active")
           return
       }
       Self.debugLog("handlePermissionPromptEnded - calling show()")
       self.show()
   }
   ```

2. **Add logging to `show()`:**
   ```swift
   func show() {
       Self.debugLog("show() called - panel exists: \(self.panel != nil)")
       // ... existing code ...
       Self.debugLog("show() completed - panel.isVisible: \(panel.isVisible), alphaValue: \(panel.alphaValue)")
   }
   ```

3. **Verify notification is posted:**
   - Check that `.permissionPromptDidEnd` is posted when permission dialog dismisses
   - Currently only posted when `activePrompts` becomes empty

### 7.2 Potential Fixes to Try

1. **Force window to front after permission granted:**
   - Add delay before calling `show()` in `handlePermissionPromptEnded()`
   - Use `DispatchQueue.main.asyncAfter` to ensure window system has settled

2. **Check window level:**
   - Permission dialogs have high window levels
   - Our panel uses `.floating` level - might need higher level temporarily

3. **Verify panel is on correct screen:**
   - Multi-monitor setups might cause panel to appear on wrong screen

4. **Check if panel needs recreation:**
   - First-time creation + immediate focus loss might corrupt panel state
   - Try recreating panel in `handlePermissionPromptEnded()`

### 7.3 Alternative Approaches

1. **Don't show overlay until permission is granted:**
   - Check permission status before showing overlay
   - Request permission in a pre-flight step
   - Only show overlay after microphone access confirmed

2. **Use a different window type:**
   - `NSPanel` with `.nonactivatingPanel` style might behave better
   - Or use a regular `NSWindow` instead

---

## 8. Related Documentation

- **X.07-FOCUS-RECOVERY.md** - Original focus recovery story (marked complete, but this bug shows it's incomplete)
- **ARCHITECTURE.md** - Section "Focus Recovery During External Operations"
- **AGENTS.md** - "Permission prompt tracking (CRITICAL)" in Review Learnings

---

## 9. Test Checklist

- [x] Fresh install: `./build.sh reset-perms && ./build.sh run`
- [x] Press hotkey
- [x] Microphone permission dialog appears
- [x] Grant permission
- [x] Overlay should be visible with listening state
- [x] Audio should be captured
- [x] LLM should process and respond
- [x] All 919 tests pass

---

## 10. Session Notes

### 2026-01-14 Session 1 (Investigation)

1. Started investigating issue where overlay disappears during microphone permission
2. Initially thought it was double-tracking issue - removed tracker calls from individual permission files
3. Calendar permission started working, but microphone still broken
4. Added debug logging to `/tmp/ora-overlay-debug.log`
5. Discovered race condition: permission dialog appears BEFORE beginPrompt() executes
6. Added pre-emptive tracking in SimplePipelineController.runListeningSession()
7. Race condition fixed - logs show session is no longer being cancelled
8. BUT: Overlay still not visible even though session continues
9. **Hypothesis:** Issue is now with overlay restoration, not session cancellation

### 2026-01-14 Session 2 (Fix)

1. Added logging to `handlePermissionPromptEnded()` and `show()` to trace restoration flow
2. Discovered panel reports `isVisible=true, isKeyWindow=false` - window ordering issue
3. Root cause: After permission dialog dismisses, window system doesn't return focus to Ora
4. Implemented `restoreAfterExternalDialog()` with:
   - 100ms delay to let window system settle
   - Activate app first
   - Temporarily bump window level to `.popUpMenu`
   - Force window ordering
   - Restore original level after 50ms
5. Tested and verified fix works
6. Cleaned up debug logging (removed file-based logging, kept OS Logger)
7. All 919 tests pass
8. **Bug fixed and verified**
