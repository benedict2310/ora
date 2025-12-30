# A.04 - Hotkey Wiring

**Epic:** ASR Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 0.5 days
**Dependencies:** A.03 (Transcript Stream), F.09 (Model Download)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Connect the global hotkey (via `AppDelegate` + `HotkeyManager`) to the `TranscriptCoordinator` to enable the end-to-end "Push-to-Talk" workflow.

This story ensures that pressing the hotkey actually *starts* the engine (which requires models from F.09) and handles any startup failures gracefully in the UI.

### Flow

1. **Hotkey Press (↓)** → `TranscriptCoordinator.startSession()`
   - Audio capture starts
   - ASR stream begins
   - UI shows "Listening"

2. **Hotkey Release (↑)** → `TranscriptCoordinator.stopSession()`
   - Audio capture stops
   - ASR finalizes
   - Final result returned (and logged for now)
   - UI shows "Thinking" -> "Done"

---

## 2. Implementation

### 2.1 TranscriptCoordinator Updates

**File:** `Ora/ASR/TranscriptCoordinator.swift`

Add a `stopSession()` method to gracefully end the recording.

```swift
actor TranscriptCoordinator {
    // ... existing properties ...

    // Add explicit stop capability
    func stopSession() {
        Task {
            // Stopping audio service will close the stream
            // which causes the loop in runSession() to finish
            await AudioService.shared.stop()
        }
    }
    
    // Update runSession to handle the stream termination naturally
    private func runSession() async throws -> String? {
        // ... (audioStream = try await AudioService.shared.start())
        // ... (asrStream = await ASRService.shared.transcribe...)
        
        // Loop runs until audioStream finishes (when stop() is called)
        for try await event in asrStream {
            // ... processing ...
        }
        
        // When loop exits, we have the final result
        return lastText.isEmpty ? nil : lastText
    }
}
```

### 2.2 AppDelegate Wiring & Error Handling

**File:** `Ora/AppDelegate.swift`

Wire the hotkey events to the coordinator and handle errors (e.g., missing models).

```swift
// In onHotkeyPress():
private func onHotkeyPress() {
    // ... UI updates ...
    
    // Start session
    Task {
        do {
            try await TranscriptCoordinator.shared.startSession()
        } catch {
            self.logger.error("Failed to start session: \(error.localizedDescription)")
            
            // Critical: Show error in UI so user knows why it failed
            await MainActor.run {
                OverlayWindowController.shared.mode = .error("Failed to start: \(error.localizedDescription)")
            }
        }
    }
}

// In onHotkeyRelease():
private func onHotkeyRelease() {
    // ... UI updates ...
    
    // Stop session (graceful finish)
    Task {
        await TranscriptCoordinator.shared.stopSession()
    }
}
```

---

## 3. Acceptance Criteria

- [ ] **AC-1:** Pressing hotkey starts audio capture (Mic icon active)
- [ ] **AC-2:** Speaking while holding hotkey updates Overlay UI with partial text
- [ ] **AC-3:** Releasing hotkey stops audio capture
- [ ] **AC-4:** Final transcript is logged/returned after release
- [ ] **AC-5:** Rapid press/release cycles do not crash the app
- [ ] **AC-6:** If models are missing (F.09 not run), UI shows a clear error message instead of crashing or doing nothing.

---

## 4. Implementation Checklist

- [ ] Update `TranscriptCoordinator.swift` with `stopSession()`
- [ ] Update `AppDelegate.swift` to call start/stop
- [ ] Verify `AudioService` stops correctly when requested
- [ ] Test error path (delete models, try hotkey)
- [ ] Test success path (download models, try hotkey)

---

## 5. Notes

- This story bridges the gap between the "Shell" (Foundation) and the "Engine" (ASR).
- It relies on F.09 to provide the models. If tested before F.09, AC-6 is the primary acceptance criterion.
