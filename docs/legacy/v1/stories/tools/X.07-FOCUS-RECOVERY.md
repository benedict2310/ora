# X.07 — Focus Recovery & External Operations

**Epic:** Tools  
**Status:** Complete  
**Priority:** P1 (Critical)  
**Estimated Effort:** 0.5 days  
**Dependencies:** X.05 (System Tools)  
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Ensure the **Ora overlay remains visible and active** when tools trigger external operations that temporarily steal focus (e.g., opening apps, system dialogs, URLs) or when the user interacts with permission prompts.

Previously, opening an external app or URL caused the overlay to resign active state, which triggered an immediate session cancellation. This prevented the assistant from confirming the action was completed ("Okay, I've opened Safari").

---

## 2. Problem Statement

The overlay automatically hides and cancels the session when it loses focus (`NSApplication.didResignActiveNotification`). This is desired behavior for user-initiated context switching (clicking another window), but it breaks the flow for:

1.  **Tool-initiated switching:** Opening Safari, Finder, or System Settings.
2.  **System dialogs:** Microphone, Calendar, or Accessibility permission prompts.

We need a way to distinguish "I clicked away" (cancel) from "The tool opened something" (wait and restore).

---

## 3. Solution: External Focus Tracker

### 3.1 Concept

Introduce a singleton `ExternalFocusTracker` that maintains a reference count of active "external operations".

- **Start Operation:** Increment count.
- **End Operation:** Decrement count (after a short delay to allow focus to settle).
- **Check:** `OverlayWindowController` checks this tracker before cancelling on resign active.

### 3.2 Implementation

**File:** `Ora/Permissions/ExternalFocusTracker.swift`

```swift
@MainActor
final class ExternalFocusTracker {
    static let shared = ExternalFocusTracker()
    
    private var activeOperationCount: Int = 0
    
    var isExternalOperationActive: Bool {
        return activeOperationCount > 0
    }
    
    func withExternalOperation<T>(_ operation: () async throws -> T) async rethrows -> T {
        self.beginExternalOperation()
        let result = try await operation()
        
        // Wait for focus changes to propagate (vital for NSWorkspace operations)
        try? await Task.sleep(for: .milliseconds(500))
        
        self.endExternalOperation()
        return result
    }
    
    private func beginExternalOperation() {
        activeOperationCount += 1
    }
    
    private func endExternalOperation() {
        if activeOperationCount > 0 {
            activeOperationCount -= 1
        }
    }
}
```

### 3.3 Overlay Logic Update

**File:** `Ora/Overlay/OverlayWindowController.swift`

Modified `handleAppDeactivated()`:

```swift
private func handleAppDeactivated() {
    // 1. Check permission prompts
    if PermissionMonitor.shared.isPromptVisible {
        return // Keep overlay
    }
    
    // 2. Check external tool operations
    if ExternalFocusTracker.shared.isExternalOperationActive {
        return // Keep overlay
    }
    
    // 3. Otherwise, cancel session
    self.cancelHandler()
}
```

Also added `NSApplication.didBecomeActiveNotification` observer to **restore** the overlay if it was hidden but the session is still active (e.g., coming back from a permission prompt).

---

## 4. Integration Points

The following tools now wrap their execution in `ExternalFocusTracker`:

- `SystemOpenAppTool`
- `SystemOpenURLTool`
- `SystemOpenPathTool`
- `SystemRevealInFinderTool`
- `SystemOpenFolderSpecialTool`
- `SystemOpenSettingsTool`

Example:

```swift
func execute(...) async throws -> ToolResult {
    return await ExternalFocusTracker.shared.withExternalOperation {
        // NSWorkspace call that steals focus
        NSWorkspace.shared.open(url)
        return .success(...)
    }
}
```

---

## 5. Verification

### Scenarios

1.  **Open URL:**
    - User: "Open apple.com"
    - Ora: Calls `system.open_url`
    - Browser opens (steals focus)
    - Ora Overlay: Remains visible (dimmed) or restores focus after browser opens?
    - **Result:** Overlay stays visible/active enough to speak "Opened Apple.com in your browser."

2.  **Permission Prompt:**
    - User: "Add event to calendar" (First time)
    - System: Shows "Ora would like to access Calendar"
    - Ora: Waits.
    - User: Clicks "Allow"
    - Ora: Regains focus and completes the action.

3.  **Manual Switch:**
    - User: Clicks Desktop wallpaper while Ora is talking.
    - Ora: Cancels session and hides immediately.

---

## 6. Completion Status

- [x] `ExternalFocusTracker` implemented
- [x] Overlay logic updated to respect tracker
- [x] All system tools updated to use tracker
- [x] Verified with manual testing (Opening Safari, Finder)
- [x] Merged to main

**Date:** 2026-01-10
