# F.01 - App Shell & Menu Bar

**Epic:** Foundations
**Status:** Completed
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** None
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create the foundational macOS application shell with menu bar presence. This establishes the app lifecycle, LSUIElement configuration (no dock icon), and basic menu bar functionality.

### Scope

**In Scope:**
- Xcode project setup with XcodeGen (`project.yml`)
- LSUIElement = true (menu bar agent, no dock icon)
- Menu bar icon with status indicator
- Basic dropdown menu (Preferences, Quit)
- App delegate lifecycle management
- Swift 6 strict concurrency configuration

**Out of Scope:**
- Permission requests (F.02)
- Model management (F.03)
- Hotkey registration (F.05)
- Preferences window content (F.06)

---

## 2. Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        AppDelegate                           │
│                     (@NSApplicationMain)                     │
├─────────────────────────────────────────────────────────────┤
│  - applicationDidFinishLaunching()                          │
│  - applicationWillTerminate()                               │
│  - Handle reopen (click dock icon if visible)               │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    StatusBarController                       │
│                      (@MainActor)                           │
├─────────────────────────────────────────────────────────────┤
│  - NSStatusItem (menu bar icon)                             │
│  - NSMenu (dropdown)                                        │
│  - State-based icon updates                                 │
│  - Menu actions (Preferences, Quit)                         │
└─────────────────────────────────────────────────────────────┘
```

### Menu Bar States

| State | Icon | Description |
|:------|:-----|:------------|
| `idle` | ○ (outline) | Ready, waiting for activation |
| `listening` | ● (filled, blue) | Recording user speech |
| `thinking` | ◐ (animated) | Processing with LLM |
| `speaking` | 🔊 (speaker) | TTS playback active |
| `error` | ⚠ (warning) | Error state |
| `setupRequired` | ⬇ (download) | Models need download |

---

## 3. Implementation

### 3.1 Project Configuration

**File:** `project.yml`

```yaml
name: Ora
options:
  bundleIdPrefix: com.ora
  deploymentTarget:
    macOS: "26.0"
  xcodeVersion: "16.0"
  
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MACOSX_DEPLOYMENT_TARGET: "26.0"
    CODE_SIGN_IDENTITY: "-"
    PRODUCT_BUNDLE_IDENTIFIER: com.ora.app
    INFOPLIST_FILE: Ora/Info.plist

targets:
  Ora:
    type: application
    platform: macOS
    sources:
      - path: Ora
    settings:
      base:
        INFOPLIST_FILE: Ora/Info.plist
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
    dependencies: []

  OraTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: OraTests
    dependencies:
      - target: Ora
```

### 3.2 Info.plist

**File:** `Ora/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Menu bar agent (no dock icon) -->
    <key>LSUIElement</key>
    <true/>
    
    <!-- App identity -->
    <key>CFBundleName</key>
    <string>Ora</string>
    <key>CFBundleDisplayName</key>
    <string>Ora</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    
    <!-- Permissions (descriptions) -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Ora needs microphone access to hear your voice commands.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Ora needs calendar access to manage your events.</string>
    <key>NSRemindersUsageDescription</key>
    <string>Ora needs reminders access to create and manage tasks.</string>
    <key>NSContactsUsageDescription</key>
    <string>Ora needs contacts access to look up people you mention.</string>
    
    <!-- Minimum system -->
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
```

### 3.3 App Entry Point

**File:** `Ora/main.swift`

```swift
//
//  main.swift
//  Ora
//
//  Application entry point
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

### 3.4 AppDelegate

**File:** `Ora/AppDelegate.swift`

```swift
//
//  AppDelegate.swift
//  Ora
//
//  Main application delegate
//

import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    
    // MARK: - Properties
    
    private var statusBarController: StatusBarController?
    private let logger = Logger(subsystem: "com.ora.app", category: "AppDelegate")
    
    // MARK: - NSApplicationDelegate
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Ora launching...")
        
        // Initialize status bar
        self.statusBarController = StatusBarController()
        
        // Set activation policy (accessory = menu bar only)
        NSApp.setActivationPolicy(.accessory)
        
        logger.info("Ora ready")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Ora terminating...")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If user clicks dock icon (if visible), show preferences or activate
        statusBarController?.showPreferences()
        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
```

### 3.5 StatusBarController

**File:** `Ora/UI/StatusBarController.swift`

```swift
//
//  StatusBarController.swift
//  Ora
//
//  Menu bar icon and dropdown menu management
//

import AppKit
import os

@MainActor
final class StatusBarController {
    
    // MARK: - Types
    
    enum State: Equatable, Sendable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)
        case setupRequired
    }
    
    // MARK: - Properties
    
    private var statusItem: NSStatusItem?
    private let logger = Logger(subsystem: "com.ora.app", category: "StatusBar")
    
    private(set) var state: State = .idle {
        didSet {
            updateIcon()
        }
    }
    
    // MARK: - Initialization
    
    init() {
        setupStatusItem()
    }
    
    // MARK: - Public API
    
    func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        logger.debug("Status bar state: \(String(describing: newState))")
    }
    
    func showPreferences() {
        // Will be implemented in F.06
        logger.debug("Show preferences requested")
    }
    
    // MARK: - Private Setup
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else {
            logger.error("Failed to create status bar button")
            return
        }
        
        // Set initial icon
        button.image = iconForState(.idle)
        button.image?.isTemplate = true
        
        // Create menu
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(preferencesClicked), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Ora", action: #selector(quitClicked), keyEquivalent: "q"))
        
        // Set targets
        for item in menu.items {
            item.target = self
        }
        
        statusItem?.menu = menu
        
        logger.debug("Status bar initialized")
    }
    
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        button.image = iconForState(state)
        button.image?.isTemplate = (state != .error(""))
    }
    
    private func iconForState(_ state: State) -> NSImage? {
        let symbolName: String
        switch state {
        case .idle:
            symbolName = "circle"
        case .listening:
            symbolName = "circle.fill"
        case .thinking:
            symbolName = "circle.dotted"
        case .speaking:
            symbolName = "speaker.wave.2.fill"
        case .error:
            symbolName = "exclamationmark.triangle"
        case .setupRequired:
            symbolName = "arrow.down.circle"
        }
        
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ora")?
            .withSymbolConfiguration(config)
    }
    
    // MARK: - Actions
    
    @objc private func preferencesClicked() {
        showPreferences()
    }
    
    @objc private func quitClicked() {
        logger.info("Quit requested by user")
        NSApp.terminate(nil)
    }
}
```

---

## 4. Directory Structure

After this story, the project should have:

```
Ora/
├── Ora/
│   ├── main.swift
│   ├── AppDelegate.swift
│   ├── Info.plist
│   └── UI/
│       └── StatusBarController.swift
├── OraTests/
│   └── StatusBarControllerTests.swift
├── project.yml
└── build.sh
```

---

## 5. Acceptance Criteria

### Core Functionality

- [x] **AC-1:** App builds and runs without errors
- [x] **AC-2:** App appears in menu bar with icon (not in dock)
- [x] **AC-3:** Clicking menu bar icon shows dropdown menu
- [x] **AC-4:** "Quit Ora" menu item terminates the app
- [x] **AC-5:** "Preferences..." menu item triggers action (stub for F.06)

### Configuration

- [x] **AC-6:** `LSUIElement` is true in Info.plist
- [x] **AC-7:** Swift 6 strict concurrency enabled
- [x] **AC-8:** Deployment target is macOS 26

### State Management

- [x] **AC-9:** `StatusBarController.State` enum has all required cases
- [x] **AC-10:** Icon updates when state changes
- [x] **AC-11:** State changes are logged

---

## 6. Test Cases

### 6.1 StatusBarController Tests

```swift
// StatusBarControllerTests.swift

import XCTest
@testable import Ora

@MainActor
final class StatusBarControllerTests: XCTestCase {
    
    // TC-1: Initial state is idle
    func test_initialState_isIdle() {
        let controller = StatusBarController()
        XCTAssertEqual(controller.state, .idle)
    }
    
    // TC-2: State can be changed
    func test_setState_updatesState() {
        let controller = StatusBarController()
        controller.setState(.listening)
        XCTAssertEqual(controller.state, .listening)
    }
    
    // TC-3: Same state is ignored
    func test_setState_sameState_noChange() {
        let controller = StatusBarController()
        controller.setState(.idle)
        // Should not crash or log
        XCTAssertEqual(controller.state, .idle)
    }
    
    // TC-4: Error state carries message
    func test_errorState_hasMessage() {
        let controller = StatusBarController()
        controller.setState(.error("Test error"))
        if case .error(let message) = controller.state {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Expected error state")
        }
    }
}
```

---

## 7. Implementation Checklist

- [x] Create `project.yml` with XcodeGen configuration
- [x] Create `Ora/Info.plist` with LSUIElement and permissions
- [x] Create `Ora/main.swift` entry point
- [x] Create `Ora/AppDelegate.swift`
- [x] Create `Ora/UI/StatusBarController.swift`
- [x] Create `build.sh` script
- [x] Generate Xcode project with `xcodegen generate`
- [x] Build and verify menu bar icon appears
- [x] Verify quit functionality works
- [x] Add unit tests

---

## 8. Notes

### Why AppKit for Menu Bar?

SwiftUI's `MenuBarExtra` (macOS 13+) is simpler but less flexible:
- Limited control over menu appearance
- Harder to implement custom button behavior (click vs hold)
- AppKit `NSStatusItem` provides full control needed for PTT activation

### LSUIElement Behavior

With `LSUIElement = true`:
- App does not appear in Dock
- App does not appear in Cmd+Tab switcher
- App can still show windows (preferences, overlay)
- App runs as "accessory" to the system

---

## 9. Code Review (Post-Implementation)

### Findings (All Fixed)

| Priority | Finding | Status | Resolution |
|:---------|:--------|:-------|:-----------|
| P1 | `StatusBarController` never removes its `NSStatusItem` | Fixed | Added `shutdown()` method called from `AppDelegate.applicationWillTerminate` |
| P1 | Menu actions hard-wired, blocking testability | Fixed | Introduced `StatusBarActionHandler` protocol with DI; tests use `MockStatusBarActionHandler` |
| P2 | `applicationShouldHandleReopen` always opens preferences | Fixed | Now gated on `hasVisibleWindows` flag |
| P2 | Unit tests don't validate menu/icons | Fixed | Added tests for menu items, key equivalents, and icon mapping |

### Testing + Coverage (Addressed)

| Priority | Gap | Status | Resolution |
|:---------|:----|:-------|:-----------|
| P0 | Coverage below 85% target | Fixed | 18 tests covering state, icon mapping, menu construction, action handlers, shutdown |
| P1 | No E2E test for menu bar | Deferred | Manual E2E checklist documented below |

### Manual E2E Checklist

1. Run `./build.sh run`
2. Verify menu bar icon appears (circle outline)
3. Click icon, verify dropdown shows "Preferences..." and "Quit Ora"
4. Verify Cmd+, shortcut is shown for Preferences
5. Verify Cmd+Q shortcut is shown for Quit
6. Click "Quit Ora" - app should terminate

---

## 10. Approval Check (Re-review)

**Status:** Approved

| Priority | Finding | Resolution |
|:---------|:--------|:-----------|
| P0 | `StatusBarController` stores action handler as `weak`, causing immediate deallocation | ✅ Fixed: Split into `defaultActionHandler` (strong) and `injectedActionHandler` (weak) with computed `actionHandler` property |
| P2 | E2E checklist doesn't confirm Preferences action works | ✅ Fixed: `DefaultStatusBarActionHandler.handlePreferences()` now calls `PreferencesCoordinator.shared.showPreferences()` |

### Updated E2E Checklist

1. Run `./build.sh run`
2. Verify menu bar icon appears (circle outline)
3. Click icon, verify dropdown shows "Preferences..." and "Quit Ora"
4. Verify Cmd+, shortcut is shown for Preferences
5. Verify Cmd+Q shortcut is shown for Quit
6. Click "Preferences..." - **Preferences window should open with 4 tabs**
7. Click "Quit Ora" - app should terminate

---

## 11. Re-review (Follow-up)

**Status:** Approved

- No new issues found after verifying the action handler retention and Preferences integration.
- Residual risk: E2E validation is manual only; consider adding a UI smoke test when feasible.
