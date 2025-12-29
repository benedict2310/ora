# Hotkey Handling & Overlay Creation - MacTalk Implementation Guide

> This document explains how MacTalk implements global hotkey handling and overlay window creation, step-by-step. Use this as a reference for replicating similar functionality in other macOS applications.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Component Summary](#component-summary)
3. [Step-by-Step Flow](#step-by-step-flow)
4. [Implementation Details](#implementation-details)
5. [Code Snippets for Reuse](#code-snippets-for-reuse)
6. [Dependencies & Imports](#dependencies--imports)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Flow                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────┐    ┌────────────────┐    ┌──────────────────┐  │
│  │   AppDelegate │───▶│ StatusBar      │───▶│   HotkeyManager  │  │
│  │              │    │ Controller     │    │ (Carbon Events)  │  │
│  └──────────────┘    └───────┬────────┘    └────────┬─────────┘  │
│                              │                       │            │
│                              │  onHotkeyPressed()    │            │
│                              │◀──────────────────────┘            │
│                              │                                    │
│                              ▼                                    │
│                    ┌─────────────────┐                           │
│                    │ HUDWindowController                         │
│                    │ (Floating Overlay)│                         │
│                    └─────────────────┘                           │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                     Settings Flow                            │ │
│  │  ┌───────────────────┐  saves   ┌─────────────────────────┐ │ │
│  │  │ SettingsWindow    │─────────▶│ UserDefaults            │ │ │
│  │  │ (ShortcutRecorder)│          │ (startMicOnlyShortcut)  │ │ │
│  │  └───────────────────┘          └───────────┬─────────────┘ │ │
│  │                                              │               │ │
│  │              posts .shortcutsDidChange       │               │ │
│  │                        │                     │               │ │
│  │                        ▼                     │               │ │
│  │  ┌───────────────────────────┐              │               │ │
│  │  │ StatusBarController       │◀─────────────┘               │ │
│  │  │ (registerShortcuts())     │                              │ │
│  │  └───────────────────────────┘                              │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Component Summary

| Component | File | Purpose |
|-----------|------|---------|
| **HotkeyManager** | `HotkeyManager.swift` | Registers global hotkeys using Carbon Event APIs |
| **KeyboardShortcut** | `ShortcutRecorderView.swift` | Model struct to store keyCode + modifiers |
| **ShortcutRecorderView** | `ShortcutRecorderView.swift` | Custom NSView to record keyboard shortcuts |
| **HUDWindowController** | `HUDWindowController.swift` | Floating overlay window (borderless, transparent) |
| **StatusBarController** | `StatusBarController.swift` | Orchestrates hotkey → action → overlay display |
| **SettingsWindowController** | `SettingsWindowController.swift` | UI for configuring shortcuts |

---

## Step-by-Step Flow

### Step 1: App Launch – Initialize HotkeyManager

When the app starts, `StatusBarController` is created, which owns a `HotkeyManager` instance.

```
AppDelegate.applicationDidFinishLaunching()
    └─▶ StatusBarController.init()
            └─▶ HotkeyManager.init()
                    └─▶ registerEventHandler()  // Installs Carbon event handler
```

### Step 2: Register Shortcuts from UserDefaults

After initialization, `StatusBarController.show()` calls `registerShortcuts()`.

```swift
// StatusBarController.swift
private func registerShortcuts() {
    // 1. Unregister existing hotkeys
    for (_, hotkeyID) in registeredHotkeyIDs {
        hotkeyManager.unregister(hotkeyID: hotkeyID)
    }
    registeredHotkeyIDs.removeAll()

    // 2. Load shortcuts from UserDefaults
    let defaults = UserDefaults.standard
    if let data = defaults.data(forKey: "startMicOnlyShortcut"),
       let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
        
        // 3. Register with HotkeyManager
        if let hotkeyID = hotkeyManager.register(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.carbonModifiers,
            handler: { [weak self] in
                self?.toggleMicOnly()  // Action to perform
            }
        ) {
            registeredHotkeyIDs["startMicOnly"] = hotkeyID
        }
    }
}
```

### Step 3: Carbon Event Handler Receives Hotkey Press

When user presses the registered hotkey anywhere in macOS:

```
[User presses ⌘⇧M globally]
    └─▶ Carbon Event System
            └─▶ HotkeyManager.callback (C function pointer)
                    └─▶ handleHotkeyPressed(id: UInt32)
                            └─▶ Task { @MainActor in handler() }
```

### Step 4: Handler Toggles Recording & Shows Overlay

```swift
// StatusBarController.swift
private func toggleMicOnly() {
    if isRecording {
        stopRecording()
    } else {
        startMicOnly()  // Sets mode, then calls startRecording()
    }
}

private func startRecording() {
    // ... setup transcription ...
    
    isRecording = true
    updateMenuBarIcon(recording: true)
    hudController?.showWindow(nil)  // ◀── SHOWS THE OVERLAY
}
```

### Step 5: HUD Window Animates In

```swift
// HUDWindowController.swift
override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    animateIn()   // Spring animation for popup effect
    reset()       // Reset internal state
}

private func animateIn() {
    guard let window = window else { return }
    
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    
    // Spring scale animation
    let springAnimation = CASpringAnimation(keyPath: "transform.scale")
    springAnimation.fromValue = 0.0
    springAnimation.toValue = 1.0
    springAnimation.damping = 15
    springAnimation.stiffness = 300
    springAnimation.duration = springAnimation.settlingDuration
    
    window.contentView?.layer?.add(springAnimation, forKey: "scaleIn")
    window.animator().alphaValue = 1.0
}
```

### Step 6: User Presses Hotkey Again to Stop

```
[User presses ⌘⇧M again]
    └─▶ toggleMicOnly()
            └─▶ stopRecording()
                    └─▶ hudController?.close()
                            └─▶ animateOut { super.close() }
```

---

## Implementation Details

### 1. HotkeyManager (Carbon Events)

The core of global hotkey registration uses the Carbon Event Manager API:

```swift
import Carbon

final class HotkeyManager {
    typealias HotkeyHandler = @MainActor @Sendable () -> Void
    
    private var hotkeys: [UInt32: (EventHotKeyRef, HotkeyHandler)] = [:]
    private var nextHotkeyID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    
    init() {
        registerEventHandler()
    }
    
    private func registerEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let callback: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )
            
            guard status == noErr else { return status }
            manager.handleHotkeyPressed(id: hotkeyID.id)
            return noErr
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }
    
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping HotkeyHandler) -> UInt32? {
        let hotkeyID = nextHotkeyID
        nextHotkeyID += 1
        
        var eventHotkey: EventHotKeyRef?
        let signature = FourCharCode("MKTK")  // Unique 4-char code for your app
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: OSType(signature), id: hotkeyID),
            GetEventDispatcherTarget(),
            0,
            &eventHotkey
        )
        
        guard status == noErr, let hotkey = eventHotkey else { return nil }
        hotkeys[hotkeyID] = (hotkey, handler)
        return hotkeyID
    }
    
    private func handleHotkeyPressed(id: UInt32) {
        guard let (_, handler) = hotkeys[id] else { return }
        Task { @MainActor in
            handler()
        }
    }
}
```

### 2. KeyboardShortcut Model

Stores the shortcut configuration and handles serialization:

```swift
import Carbon

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifierFlags: NSEvent.ModifierFlags
    
    /// Convert to Carbon modifier flags for RegisterEventHotKey
    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
    
    /// Human-readable display string (e.g., "⌘⇧M")
    var displayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }
    
    // Codable implementation (NSEvent.ModifierFlags needs custom handling)
    enum CodingKeys: String, CodingKey {
        case keyCode, modifierFlags
    }
    
    init(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let rawValue = try container.decode(UInt.self, forKey: .modifierFlags)
        modifierFlags = NSEvent.ModifierFlags(rawValue: rawValue)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifierFlags.rawValue, forKey: .modifierFlags)
    }
}
```

### 3. ShortcutRecorderView (Capture User Input)

Custom view that records keyboard shortcuts from user:

```swift
@MainActor
final class ShortcutRecorderView: NSView {
    var shortcut: KeyboardShortcut? {
        didSet {
            updateDisplay()
            onShortcutChanged?(shortcut)
        }
    }
    
    var onShortcutChanged: ((KeyboardShortcut?) -> Void)?
    
    private var isRecording = false
    private var eventMonitor: Any?
    
    private func startRecording() {
        isRecording = true
        updateDisplay()
        window?.makeFirstResponder(self)
        
        // Monitor key events locally
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil  // Consume event
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        guard isRecording else { return }
        
        // Ignore modifier-only keys
        let modifierKeyCodes = [kVK_Command, kVK_Shift, kVK_Option, kVK_Control, ...]
        if modifierKeyCodes.contains(Int(event.keyCode)) { return }
        
        // Require at least one modifier
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasModifier = modifierFlags.contains(.command) ||
                         modifierFlags.contains(.control) ||
                         modifierFlags.contains(.option) ||
                         modifierFlags.contains(.shift)
        
        guard hasModifier else {
            NSSound.beep()
            return
        }
        
        shortcut = KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            modifierFlags: modifierFlags
        )
        stopRecording()
    }
}
```

### 4. HUD Overlay Window

Create a floating, transparent overlay:

```swift
@MainActor
final class HUDWindowController: NSWindowController {
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],       // No title bar
            backing: .buffered,
            defer: false
        )
        
        // Critical window properties for overlay
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating            // Always on top
        window.collectionBehavior = [
            .canJoinAllSpaces,              // Show on all desktops
            .stationary                     // Don't move with spaces
        ]
        
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        
        // Add glass effect background
        let backgroundView = NSVisualEffectView()
        backgroundView.material = .hudWindow
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        backgroundView.layer?.cornerRadius = 100  // Circular
        backgroundView.layer?.masksToBounds = true
        backgroundView.frame = contentView.bounds
        contentView.addSubview(backgroundView)
        
        // Add your content (buttons, labels, etc.)
        // ...
    }
}
```

### 5. Saving/Loading Shortcuts (UserDefaults)

```swift
// Save
private func saveShortcut(_ shortcut: KeyboardShortcut?, forKey key: String) {
    let defaults = UserDefaults.standard
    if let shortcut = shortcut,
       let data = try? JSONEncoder().encode(shortcut) {
        defaults.set(data, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
    // Notify listeners to re-register hotkeys
    NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
}

// Load
private func loadShortcut(forKey key: String) -> KeyboardShortcut? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
}
```

---

## Code Snippets for Reuse

### Notification Names

```swift
extension Notification.Name {
    static let shortcutsDidChange = Notification.Name("shortcutsDidChange")
}
```

### Common Key Codes (from Carbon)

```swift
import Carbon

// Letters
let keyA: UInt32 = UInt32(kVK_ANSI_A)  // 0
let keyM: UInt32 = UInt32(kVK_ANSI_M)  // 46
let keyS: UInt32 = UInt32(kVK_ANSI_S)  // 1

// Special keys
let space: UInt32 = UInt32(kVK_Space)      // 49
let returnKey: UInt32 = UInt32(kVK_Return) // 36
let escape: UInt32 = UInt32(kVK_Escape)    // 53

// Function keys
let f1: UInt32 = UInt32(kVK_F1)  // 122
let f12: UInt32 = UInt32(kVK_F12) // 111
```

### Carbon Modifier Flags

```swift
import Carbon

let cmdKey = UInt32(cmdKey)         // ⌘ Command
let shiftKey = UInt32(shiftKey)     // ⇧ Shift
let optionKey = UInt32(optionKey)   // ⌥ Option/Alt
let controlKey = UInt32(controlKey) // ⌃ Control
```

---

## Dependencies & Imports

Required frameworks:
```swift
import AppKit          // NSWindow, NSView, NSEvent
import Carbon          // Global hotkey registration (RegisterEventHotKey, etc.)
import QuartzCore      // CASpringAnimation for overlay animations
```

**Important:** Carbon is a legacy framework but still the **only** reliable way to register global hotkeys on macOS. There is no modern Swift/AppKit replacement.

---

## Summary Checklist

To replicate this system in another project:

1. **Create `HotkeyManager.swift`**
   - Import Carbon
   - Use `RegisterEventHotKey()` to register hotkeys
   - Use `InstallEventHandler()` to receive events
   - Dispatch handlers to `@MainActor`

2. **Create `KeyboardShortcut` model**
   - Store `keyCode: UInt32` and `modifierFlags: NSEvent.ModifierFlags`
   - Implement `Codable` for persistence
   - Provide `carbonModifiers` computed property

3. **Create `ShortcutRecorderView`**
   - Use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` to capture
   - Require at least one modifier key
   - Ignore modifier-only keypresses

4. **Create overlay window (HUDWindowController)**
   - Use `.borderless` style mask
   - Set `backgroundColor = .clear`, `isOpaque = false`
   - Set `level = .floating`
   - Add `NSVisualEffectView` for glass effect

5. **Wire up in main controller**
   - Load shortcuts from UserDefaults on launch
   - Register hotkeys with HotkeyManager
   - Show/hide overlay in hotkey handler
   - Listen for `.shortcutsDidChange` to re-register

6. **Settings UI**
   - Add ShortcutRecorderView to settings panel
   - Save to UserDefaults when changed
   - Post notification to trigger re-registration

---

## Files to Copy

For a minimal implementation, copy these files:

| File | Lines | Purpose |
|------|-------|---------|
| `HotkeyManager.swift` | ~120 | Carbon hotkey registration |
| `ShortcutRecorderView.swift` | ~280 | Shortcut model + recorder view |
| `HUDWindowController.swift` | ~300 | Floating overlay window |
| `NotificationNames.swift` | ~15 | Shared notification names |

Total: ~715 lines of reusable code.
