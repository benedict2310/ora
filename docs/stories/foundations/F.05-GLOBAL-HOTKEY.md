# F.05 - Global Hotkey

**Epic:** Foundations
**Status:** Complete
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** F.01 (App Shell), F.02 (Permissions)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement global hotkey registration and handling for Push-to-Talk (PTT) activation. The default hotkey is `⌥Space` (Option + Space), with support for customization.

### PTT Behavior

```
┌─────────────┐           ┌─────────────┐           ┌─────────────┐
│  Hotkey     │           │  Hotkey     │           │  Release    │
│  Down       │───────────│  Held       │───────────│  (Key Up)   │
│  (Start)    │           │  (Recording)│           │  (Finalize) │
└─────────────┘           └─────────────┘           └─────────────┘
      │                         │                         │
      ▼                         ▼                         ▼
 Show Overlay            Stream Partials            Send to LLM
 Start Audio                                        Hide after response
```

### Scope

**In Scope:**
- `HotkeyManager` for registration and event handling
- Default hotkey: `⌥Space`
- Key down/up event detection (for PTT)
- Hotkey customization support
- Conflict detection (basic)
- Persistence of custom hotkey

**Out of Scope:**
- Audio capture (Parakeet stories)
- Overlay window display (F.07)
- Preferences UI for hotkey change (F.06)

---

## 2. Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      HotkeyManager                           │
│                        (Actor)                               │
├─────────────────────────────────────────────────────────────┤
│  - Registers global event monitor                           │
│  - Tracks key down/up states                                │
│  - Posts notifications for hotkey events                    │
│  - Manages hotkey configuration                             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   CGEvent / NSEvent                          │
│                  (Global Event Monitor)                      │
└─────────────────────────────────────────────────────────────┘
```

### Event Flow

```
CGEvent (keyDown/keyUp)
        │
        ▼
HotkeyManager.handleEvent()
        │
        ├── Check modifiers match
        ├── Check key code matches
        │
        ▼
Post Notification
  - .hotkeyDidPress (key down)
  - .hotkeyDidRelease (key up)
        │
        ▼
AssistantController (listener)
  - Start/stop audio capture
  - Show/hide overlay
```

---

## 3. Implementation

### 3.1 Hotkey Configuration

**File:** `Ora/Hotkey/HotkeyConfiguration.swift`

```swift
//
//  HotkeyConfiguration.swift
//  Ora
//
//  Hotkey configuration and persistence
//

import Foundation
import Carbon.HIToolbox

/// Represents a keyboard shortcut
struct HotkeyConfiguration: Codable, Equatable, Sendable {
    /// Key code (Carbon key code)
    var keyCode: UInt16
    
    /// Modifier flags
    var modifiers: UInt32
    
    /// Default hotkey: ⌥Space (Option + Space)
    static let defaultHotkey = HotkeyConfiguration(
        keyCode: UInt16(kVK_Space),
        modifiers: UInt32(optionKey)
    )
    
    /// Human-readable description
    var displayString: String {
        var parts: [String] = []
        
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        
        parts.append(keyCodeToString(keyCode))
        
        return parts.joined()
    }
    
    private func keyCodeToString(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ANSI_A...kVK_ANSI_Z:
            // Convert to letter
            let letters = "ASDFHGZXCVBQWERTYUIOPNMLKJ"
            let index = Int(code) - kVK_ANSI_A
            if index < letters.count {
                return String(letters[letters.index(letters.startIndex, offsetBy: index)])
            }
            return "?"
        default:
            return "Key\(code)"
        }
    }
}

// MARK: - Persistence

extension HotkeyConfiguration {
    private static let userDefaultsKey = "com.ora.hotkeyConfiguration"
    
    /// Load saved configuration or return default
    static func load() -> HotkeyConfiguration {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(HotkeyConfiguration.self, from: data) else {
            return .defaultHotkey
        }
        return config
    }
    
    /// Save configuration
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: HotkeyConfiguration.userDefaultsKey)
        }
    }
}
```

### 3.2 Hotkey Manager

**File:** `Ora/Hotkey/HotkeyManager.swift`

```swift
//
//  HotkeyManager.swift
//  Ora
//
//  Global hotkey registration and event handling
//

import Foundation
import AppKit
import Carbon.HIToolbox
import os

// MARK: - Notifications

extension Notification.Name {
    /// Posted when hotkey is pressed down (start PTT)
    static let hotkeyDidPress = Notification.Name("hotkeyDidPress")
    
    /// Posted when hotkey is released (end PTT)
    static let hotkeyDidRelease = Notification.Name("hotkeyDidRelease")
}

// MARK: - Hotkey Manager

@MainActor
final class HotkeyManager {
    
    // MARK: - Singleton
    
    static let shared = HotkeyManager()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "HotkeyManager")
    
    private var configuration: HotkeyConfiguration
    private var eventMonitor: Any?
    private var isHotkeyDown = false
    private var isEnabled = false
    
    /// Current hotkey configuration
    var currentHotkey: HotkeyConfiguration {
        configuration
    }
    
    /// Whether the hotkey is currently being held
    var isPressed: Bool {
        isHotkeyDown
    }
    
    // MARK: - Initialization
    
    private init() {
        self.configuration = HotkeyConfiguration.load()
    }
    
    // MARK: - Public API
    
    /// Start listening for hotkey events
    func start() {
        guard !isEnabled else {
            logger.debug("Hotkey manager already started")
            return
        }
        
        // Check accessibility permission
        guard AXIsProcessTrusted() else {
            logger.error("Cannot start hotkey manager: Accessibility permission not granted")
            return
        }
        
        // Register global event monitor
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleEvent(event)
        }
        
        isEnabled = true
        logger.info("Hotkey manager started, listening for \(self.configuration.displayString)")
    }
    
    /// Stop listening for hotkey events
    func stop() {
        guard isEnabled else { return }
        
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        isHotkeyDown = false
        isEnabled = false
        logger.info("Hotkey manager stopped")
    }
    
    /// Update hotkey configuration
    func setHotkey(_ config: HotkeyConfiguration) {
        let wasEnabled = isEnabled
        
        if wasEnabled {
            stop()
        }
        
        configuration = config
        configuration.save()
        logger.info("Hotkey updated to \(config.displayString)")
        
        if wasEnabled {
            start()
        }
    }
    
    /// Reset to default hotkey
    func resetToDefault() {
        setHotkey(.defaultHotkey)
    }
    
    /// Check if a hotkey configuration conflicts with system shortcuts
    func checkForConflicts(_ config: HotkeyConfiguration) -> Bool {
        // Known system shortcuts to avoid
        let conflicts: [(keyCode: UInt16, modifiers: UInt32)] = [
            // Spotlight: ⌘Space
            (UInt16(kVK_Space), UInt32(cmdKey)),
            // Screenshot: ⌘⇧3, ⌘⇧4, ⌘⇧5
            (UInt16(kVK_ANSI_3), UInt32(cmdKey | shiftKey)),
            (UInt16(kVK_ANSI_4), UInt32(cmdKey | shiftKey)),
            (UInt16(kVK_ANSI_5), UInt32(cmdKey | shiftKey)),
        ]
        
        for conflict in conflicts {
            if config.keyCode == conflict.keyCode && config.modifiers == conflict.modifiers {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Private: Event Handling
    
    private func handleEvent(_ event: NSEvent) {
        // Check if this is our hotkey
        guard matchesHotkey(event) else { return }
        
        switch event.type {
        case .keyDown:
            handleKeyDown(event)
        case .keyUp:
            handleKeyUp(event)
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }
    
    private func matchesHotkey(_ event: NSEvent) -> Bool {
        // For Space with Option, we need to check:
        // 1. Key code matches
        // 2. Required modifiers are present
        
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.carbonFlags
        
        // Check key code
        if keyCode != configuration.keyCode {
            return false
        }
        
        // Check modifiers (must have at least the required ones)
        let requiredModifiers = configuration.modifiers
        let hasRequired = (modifiers & requiredModifiers) == requiredModifiers
        
        return hasRequired
    }
    
    private func handleKeyDown(_ event: NSEvent) {
        // Ignore repeat events
        guard !event.isARepeat else { return }
        
        guard !isHotkeyDown else { return }
        isHotkeyDown = true
        
        logger.debug("Hotkey pressed")
        NotificationCenter.default.post(name: .hotkeyDidPress, object: nil)
    }
    
    private func handleKeyUp(_ event: NSEvent) {
        guard isHotkeyDown else { return }
        isHotkeyDown = false
        
        logger.debug("Hotkey released")
        NotificationCenter.default.post(name: .hotkeyDidRelease, object: nil)
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        // Handle case where modifier is released before key
        // This can happen if user releases Option before Space
        
        let modifiers = event.modifierFlags.carbonFlags
        let requiredModifiers = configuration.modifiers
        
        // If we were holding the hotkey but modifiers no longer match
        if isHotkeyDown && (modifiers & requiredModifiers) != requiredModifiers {
            isHotkeyDown = false
            logger.debug("Hotkey released (modifier released)")
            NotificationCenter.default.post(name: .hotkeyDidRelease, object: nil)
        }
    }
}

// MARK: - NSEvent.ModifierFlags Extension

extension NSEvent.ModifierFlags {
    /// Convert to Carbon modifier flags
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }
}
```

### 3.3 Hotkey Recorder View (for Preferences)

**File:** `Ora/Hotkey/HotkeyRecorderView.swift`

```swift
//
//  HotkeyRecorderView.swift
//  Ora
//
//  SwiftUI view for recording a new hotkey
//

import SwiftUI
import Carbon.HIToolbox

struct HotkeyRecorderView: View {
    @Binding var configuration: HotkeyConfiguration
    @State private var isRecording = false
    @State private var showConflictWarning = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Current hotkey display
                Text(configuration.displayString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isRecording ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                
                Button(isRecording ? "Cancel" : "Change") {
                    if isRecording {
                        isRecording = false
                    } else {
                        startRecording()
                    }
                }
                .buttonStyle(.bordered)
                
                Button("Reset") {
                    configuration = .defaultHotkey
                    HotkeyManager.shared.setHotkey(configuration)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            
            if isRecording {
                Text("Press your desired hotkey combination...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if showConflictWarning {
                Label("This hotkey may conflict with system shortcuts.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            setupEventMonitor()
        }
    }
    
    private func startRecording() {
        isRecording = true
        showConflictWarning = false
        // Temporarily stop the hotkey manager while recording
        HotkeyManager.shared.stop()
    }
    
    private func setupEventMonitor() {
        // Local event monitor for recording
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if isRecording {
                recordHotkey(from: event)
                return nil // Consume the event
            }
            return event
        }
    }
    
    private func recordHotkey(from event: NSEvent) {
        guard isRecording else { return }
        
        // Ignore modifier-only presses
        guard event.keyCode != 0 else { return }
        
        let newConfig = HotkeyConfiguration(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.carbonFlags
        )
        
        // Check for conflicts
        if HotkeyManager.shared.checkForConflicts(newConfig) {
            showConflictWarning = true
        } else {
            showConflictWarning = false
        }
        
        configuration = newConfig
        isRecording = false
        
        // Apply and restart
        HotkeyManager.shared.setHotkey(newConfig)
        HotkeyManager.shared.start()
    }
}
```

---

## 4. Integration with AppDelegate

**Update:** `Ora/AppDelegate.swift`

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // ... existing code ...
    
    // Start hotkey manager after setup is complete
    NotificationCenter.default.addObserver(
        forName: .setupDidComplete,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.startHotkeyManager()
    }
    
    // Also start if setup was already complete
    if UserDefaults.standard.bool(forKey: "com.ora.setupComplete") {
        startHotkeyManager()
    }
}

private func startHotkeyManager() {
    // Verify accessibility permission
    guard AXIsProcessTrusted() else {
        logger.warning("Accessibility not granted, hotkey disabled")
        return
    }
    
    HotkeyManager.shared.start()
    
    // Listen for hotkey events
    NotificationCenter.default.addObserver(
        forName: .hotkeyDidPress,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.onHotkeyPress()
    }
    
    NotificationCenter.default.addObserver(
        forName: .hotkeyDidRelease,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.onHotkeyRelease()
    }
}

private func onHotkeyPress() {
    logger.debug("Hotkey pressed - start PTT")
    statusBarController?.setState(.listening)
    // Will trigger overlay and audio capture
}

private func onHotkeyRelease() {
    logger.debug("Hotkey released - end PTT")
    statusBarController?.setState(.thinking)
    // Will finalize transcription and send to LLM
}
```

---

## 5. Acceptance Criteria

### Core Functionality

- [x] **AC-1:** `HotkeyManager.shared` provides singleton access - ✅ Verified in `HotkeyManager.swift:28`
- [x] **AC-2:** `start()` begins listening for hotkey events - ✅ Verified in `HotkeyManager.swift:62-86`
- [x] **AC-3:** `stop()` stops listening - ✅ Verified in `HotkeyManager.swift:89-103`
- [x] **AC-4:** Default hotkey is `⌥Space` - ✅ Verified by test `test_defaultHotkey_isOptionSpace`

### Event Handling

- [x] **AC-5:** `.hotkeyDidPress` posted on key down - ✅ Verified in `HotkeyManager.swift:175`
- [x] **AC-6:** `.hotkeyDidRelease` posted on key up - ✅ Verified in `HotkeyManager.swift:183`
- [x] **AC-7:** Repeated key down events are ignored (no spam) - ✅ Verified in `HotkeyManager.swift:167` (`isARepeat` check)
- [x] **AC-8:** Release detected even if modifier released first - ✅ Verified in `HotkeyManager.swift:186-197`

### Configuration

- [x] **AC-9:** Custom hotkey can be set via `setHotkey(_:)` - ✅ Verified by test `test_setHotkey_updatesCurrentHotkey`
- [x] **AC-10:** Configuration persisted to UserDefaults - ✅ Verified by test `test_configuration_persistence`
- [x] **AC-11:** `resetToDefault()` restores `⌥Space` - ✅ Verified by test `test_resetToDefault_restoresDefaultHotkey`

### Safety

- [x] **AC-12:** Cannot start without Accessibility permission - ✅ Verified in `HotkeyManager.swift:66-70`
- [x] **AC-13:** Basic conflict detection for system shortcuts - ✅ Verified by multiple `test_conflictDetection_*` tests
- [x] **AC-14:** Display string shows correct symbols (⌥, ⌘, ⇧, ⌃) - ✅ Verified by test `test_displayString_allModifiers`

---

## 6. Test Cases

```swift
// HotkeyManagerTests.swift

import XCTest
@testable import Ora

@MainActor
final class HotkeyManagerTests: XCTestCase {
    
    // TC-1: Default configuration
    func test_defaultHotkey_isOptionSpace() {
        let config = HotkeyConfiguration.defaultHotkey
        XCTAssertEqual(config.keyCode, UInt16(kVK_Space))
        XCTAssertEqual(config.modifiers, UInt32(optionKey))
    }
    
    // TC-2: Display string
    func test_displayString_optionSpace() {
        let config = HotkeyConfiguration.defaultHotkey
        XCTAssertEqual(config.displayString, "⌥Space")
    }
    
    // TC-3: Conflict detection
    func test_conflictDetection_cmdSpace() {
        let manager = HotkeyManager.shared
        let spotlightConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_Space),
            modifiers: UInt32(cmdKey)
        )
        XCTAssertTrue(manager.checkForConflicts(spotlightConfig))
    }
    
    // TC-4: No conflict for option space
    func test_conflictDetection_optionSpace_noConflict() {
        let manager = HotkeyManager.shared
        let config = HotkeyConfiguration.defaultHotkey
        XCTAssertFalse(manager.checkForConflicts(config))
    }
    
    // TC-5: Configuration persistence
    func test_configuration_persistence() {
        let testConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_O),
            modifiers: UInt32(cmdKey | shiftKey)
        )
        testConfig.save()
        
        let loaded = HotkeyConfiguration.load()
        XCTAssertEqual(loaded, testConfig)
        
        // Reset
        HotkeyConfiguration.defaultHotkey.save()
    }
}
```

---

## 7. Directory Structure

```
Ora/
└── Hotkey/
    ├── HotkeyConfiguration.swift
    ├── HotkeyManager.swift
    └── HotkeyRecorderView.swift
```

---

## 8. Implementation Checklist

- [x] Create `HotkeyConfiguration.swift`
- [x] Create `HotkeyManager.swift`
- [x] Create `HotkeyRecorderView.swift`
- [x] Integrate with AppDelegate
- [x] Test PTT flow (key down → key up)
- [x] Test hotkey customization
- [x] Test persistence
- [x] Verify accessibility permission check

---

## 9. Notes

### Why Not CGEventTap?

`CGEventTap` is more powerful but:
- Requires more complex setup
- Can be disabled by system preferences
- `NSEvent.addGlobalMonitorForEvents` is simpler and sufficient for our needs

### Accessibility Permission

The hotkey manager **will not work** without Accessibility permission because:
- Global event monitoring requires accessibility access
- This is enforced by macOS security

The app should gracefully handle missing permission:
1. Show warning in status bar
2. Provide "Open Settings" button
3. Poll for permission status changes

### PTT Timing Considerations

- Key down → key up should feel instant
- No artificial debounce needed for PTT
- Handle edge case: modifier released before key (treat as release)

---

## Implementation Summary

**Date:** 2025-12-28
**Branch:** `feat/F.05-global-hotkey`

### Files Changed

| File | Status | Description |
|:-----|:-------|:------------|
| `Ora/Hotkey/HotkeyManager.swift` | Created | Core hotkey manager singleton with global event monitoring |
| `Ora/Hotkey/HotkeyConfiguration.swift` | Modified | Fixed F-key range handling (Carbon key codes are non-contiguous) |
| `Ora/Hotkey/HotkeyRecorderView.swift` | Modified | Updated to use HotkeyManager for conflict detection and configuration |
| `Ora/AppDelegate.swift` | Modified | Integrated hotkey manager start/stop and event handlers |
| `OraTests/HotkeyManagerTests.swift` | Created | 39 tests for configuration, manager, and notifications |

### Test Coverage

- **HotkeyConfigurationTests:** 14 tests (display strings, persistence, equatable)
- **HotkeyManagerTests:** 17 tests (singleton, conflict detection, configuration changes, start/stop)
- **HotkeyNotificationTests:** 2 tests (notification names)
- **ModifierFlagsExtensionTests:** 6 tests (Carbon flag conversion)

**Total:** 39 new tests, all passing

### Ready for Review

- [x] All acceptance criteria verified (14/14)
- [x] Tests passing (167 total, 0 failures)
- [x] Working tree clean

---

## Code Review Findings

**Reviewer:** Claude Code Review Agent
**Date:** 2025-12-28
**Commit reviewed:** 1018130

### Summary

- Files reviewed: 6
- Tests run: Yes (167 tests, all passing)
- Build status: Pass

### Review Checklist

#### Correctness & Logic
- [x] Implementation matches acceptance criteria (14/14 ACs verified)
- [x] Edge cases handled (repeat key events, modifier-before-key release)
- [x] Error handling appropriate (graceful failure without accessibility permission)
- [x] No obvious bugs or logic errors

#### Architecture & Design
- [x] Changes follow existing patterns in the codebase (singleton, MARK organization, explicit self)
- [x] No unnecessary coupling introduced
- [x] Appropriate separation of concerns (Configuration, Manager, View)
- [x] Reuses existing patterns (notification-based communication)

#### Integration & Regressions
- [x] Changes integrate correctly with existing components (AppDelegate, SetupCoordinator)
- [x] No breaking changes to public APIs
- [x] No regressions in related functionality

#### Test Coverage
- [x] New code has corresponding tests (39 new tests)
- [x] Tests cover happy path and error cases
- [x] Tests are deterministic (no flaky tests observed)

#### Security & Performance
- [x] No hardcoded secrets or credentials
- [x] Input validation present (accessibility check before start)
- [x] No obvious performance regressions
- [x] Memory management correct (weak self in closures, proper cleanup in stop())

#### Code Quality
- [x] Code is readable and self-documenting
- [x] Naming is clear and consistent
- [x] No dead code or commented-out blocks
- [x] Good use of MARK organization

### Issues Found

#### P0 - Critical (Must fix before merge)
(None)

#### P1 - Major (Should fix before merge)
(None)

#### P2 - Minor (Can fix in follow-up)
(None)

### Notes

1. **F-key Fix:** The fix for Carbon F-key codes being non-contiguous was necessary and correct. The original range `kVK_F1...kVK_F12` caused a runtime crash.

2. **Event Dispatch:** The use of `Task { @MainActor in }` in event handlers creates a new task per event. This is acceptable for PTT (low event frequency) but worth monitoring if used for higher-frequency events in the future.

3. **Conflict Detection:** The basic conflict detection covers common system shortcuts. Future enhancement could include reading from system preferences, but this is out of scope for v1.

### Approval Status

- [x] All P0 issues resolved (none found)
- [x] All P1 issues resolved (none found)
- [x] Coverage target met (39 new tests, all paths covered)
- [x] Ready for merge

---

## Completion Status

- [x] Implementation complete
- [x] Code review passed (1 iteration)
- [x] PR merged: https://github.com/benedict2310/ora/pull/4
- [x] Merged to main: a521c9e
- [x] Post-merge verification passed
- [x] Date completed: 2025-12-28
