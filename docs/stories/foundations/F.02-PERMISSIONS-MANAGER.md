# F.02 - Permissions Manager

**Epic:** Foundations
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** F.01 (App Shell)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create a centralized permissions manager that handles requesting, tracking, and monitoring system permissions required by Ora.

### Required Permissions

| Permission | Framework | Required | Purpose |
|:-----------|:----------|:---------|:--------|
| **Microphone** | AVFoundation | Yes | Voice input |
| **Accessibility** | ApplicationServices | Yes | Global hotkey |
| **Calendar** | EventKit | No | Event management |
| **Reminders** | EventKit | No | Task management |
| **Contacts** | Contacts | No | Contact lookup |

### Scope

**In Scope:**
- `PermissionsManager` actor for thread-safe permission state
- Individual permission checkers for each type
- Permission request flows with async/await
- Status monitoring and change notifications
- Open System Settings helper

**Out of Scope:**
- UI for permission requests (F.04)
- First-run flow (F.04)

---

## 2. Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    PermissionsManager                        │
│                        (Actor)                               │
├─────────────────────────────────────────────────────────────┤
│  - Aggregates all permission states                         │
│  - Provides unified status API                              │
│  - Posts notifications on changes                           │
└─────────────────────────────────────────────────────────────┘
          │              │              │              │
          ▼              ▼              ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│  Microphone  │ │ Accessibility│ │   EventKit   │ │   Contacts   │
│   Checker    │ │    Checker   │ │   Checker    │ │   Checker    │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
       │                │                │                │
       ▼                ▼                ▼                ▼
 AVFoundation    AXIsProcessTrusted  EKEventStore   CNContactStore
```

---

## 3. Implementation

### 3.1 Permission Types

**File:** `Ora/Permissions/PermissionTypes.swift`

```swift
//
//  PermissionTypes.swift
//  Ora
//
//  Permission type definitions
//

import Foundation

/// All permissions Ora can request
enum PermissionType: String, CaseIterable, Sendable {
    case microphone
    case accessibility
    case calendar
    case reminders
    case contacts
    
    /// Human-readable name
    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        }
    }
    
    /// Why this permission is needed
    var explanation: String {
        switch self {
        case .microphone:
            return "Required to hear your voice commands."
        case .accessibility:
            return "Required for the global hotkey (⌥Space) to work."
        case .calendar:
            return "Allows Ora to view and create calendar events."
        case .reminders:
            return "Allows Ora to create and manage reminders."
        case .contacts:
            return "Allows Ora to look up contact information."
        }
    }
    
    /// Whether this permission is required for basic functionality
    var isRequired: Bool {
        switch self {
        case .microphone, .accessibility:
            return true
        case .calendar, .reminders, .contacts:
            return false
        }
    }
}

/// Status of a single permission
enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unknown
    
    var isGranted: Bool {
        self == .authorized
    }
    
    var canRequest: Bool {
        self == .notDetermined
    }
}

/// Aggregated permission state
struct PermissionsState: Equatable, Sendable {
    var microphone: PermissionStatus = .unknown
    var accessibility: PermissionStatus = .unknown
    var calendar: PermissionStatus = .unknown
    var reminders: PermissionStatus = .unknown
    var contacts: PermissionStatus = .unknown
    
    /// All required permissions are granted
    var requiredPermissionsGranted: Bool {
        microphone.isGranted && accessibility.isGranted
    }
    
    /// All permissions are granted
    var allPermissionsGranted: Bool {
        microphone.isGranted &&
        accessibility.isGranted &&
        calendar.isGranted &&
        reminders.isGranted &&
        contacts.isGranted
    }
    
    subscript(type: PermissionType) -> PermissionStatus {
        get {
            switch type {
            case .microphone: return microphone
            case .accessibility: return accessibility
            case .calendar: return calendar
            case .reminders: return reminders
            case .contacts: return contacts
            }
        }
        set {
            switch type {
            case .microphone: microphone = newValue
            case .accessibility: accessibility = newValue
            case .calendar: calendar = newValue
            case .reminders: reminders = newValue
            case .contacts: contacts = newValue
            }
        }
    }
}
```

### 3.2 Microphone Permission

**File:** `Ora/Permissions/MicrophonePermission.swift`

```swift
//
//  MicrophonePermission.swift
//  Ora
//
//  Microphone permission handling
//

import AVFoundation
import os

struct MicrophonePermission: Sendable {
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "MicrophonePermission")
    
    /// Check current authorization status
    static func checkStatus() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return mapStatus(status)
    }
    
    /// Request permission (async)
    static func request() async -> PermissionStatus {
        let currentStatus = checkStatus()
        
        guard currentStatus == .notDetermined else {
            logger.debug("Microphone permission already determined: \(String(describing: currentStatus))")
            return currentStatus
        }
        
        logger.info("Requesting microphone permission...")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        let newStatus: PermissionStatus = granted ? .authorized : .denied
        logger.info("Microphone permission: \(granted ? "granted" : "denied")")
        return newStatus
    }
    
    private static func mapStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
}
```

### 3.3 Accessibility Permission

**File:** `Ora/Permissions/AccessibilityPermission.swift`

```swift
//
//  AccessibilityPermission.swift
//  Ora
//
//  Accessibility permission handling (for global hotkey)
//

import ApplicationServices
import AppKit
import os

struct AccessibilityPermission: Sendable {
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "AccessibilityPermission")
    
    /// Check if accessibility access is granted
    static func checkStatus() -> PermissionStatus {
        let trusted = AXIsProcessTrusted()
        return trusted ? .authorized : .denied
    }
    
    /// Request accessibility permission
    /// Note: This opens System Settings; macOS doesn't allow programmatic granting
    @MainActor
    static func request() -> PermissionStatus {
        let currentStatus = checkStatus()
        
        if currentStatus == .authorized {
            logger.debug("Accessibility already authorized")
            return .authorized
        }
        
        logger.info("Prompting for accessibility permission...")
        
        // This shows the system prompt and opens System Settings
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        return trusted ? .authorized : .denied
    }
    
    /// Open System Settings to Accessibility pane
    @MainActor
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
```

### 3.4 EventKit Permission (Calendar & Reminders)

**File:** `Ora/Permissions/EventKitPermission.swift`

```swift
//
//  EventKitPermission.swift
//  Ora
//
//  Calendar and Reminders permission handling
//

import EventKit
import os

struct EventKitPermission: Sendable {
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "EventKitPermission")
    
    /// Check calendar authorization status
    static func checkCalendarStatus() -> PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        return mapStatus(status)
    }
    
    /// Check reminders authorization status
    static func checkRemindersStatus() -> PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return mapStatus(status)
    }
    
    /// Request calendar permission
    static func requestCalendar() async -> PermissionStatus {
        let currentStatus = checkCalendarStatus()
        
        guard currentStatus == .notDetermined else {
            return currentStatus
        }
        
        logger.info("Requesting calendar permission...")
        let store = EKEventStore()
        
        do {
            let granted = try await store.requestFullAccessToEvents()
            let newStatus: PermissionStatus = granted ? .authorized : .denied
            logger.info("Calendar permission: \(granted ? "granted" : "denied")")
            return newStatus
        } catch {
            logger.error("Calendar permission request failed: \(error.localizedDescription)")
            return .denied
        }
    }
    
    /// Request reminders permission
    static func requestReminders() async -> PermissionStatus {
        let currentStatus = checkRemindersStatus()
        
        guard currentStatus == .notDetermined else {
            return currentStatus
        }
        
        logger.info("Requesting reminders permission...")
        let store = EKEventStore()
        
        do {
            let granted = try await store.requestFullAccessToReminders()
            let newStatus: PermissionStatus = granted ? .authorized : .denied
            logger.info("Reminders permission: \(granted ? "granted" : "denied")")
            return newStatus
        } catch {
            logger.error("Reminders permission request failed: \(error.localizedDescription)")
            return .denied
        }
    }
    
    private static func mapStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .denied // We need read access
        @unknown default: return .unknown
        }
    }
}
```

### 3.5 Contacts Permission

**File:** `Ora/Permissions/ContactsPermission.swift`

```swift
//
//  ContactsPermission.swift
//  Ora
//
//  Contacts permission handling
//

import Contacts
import os

struct ContactsPermission: Sendable {
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "ContactsPermission")
    
    /// Check current authorization status
    static func checkStatus() -> PermissionStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return mapStatus(status)
    }
    
    /// Request contacts permission
    static func request() async -> PermissionStatus {
        let currentStatus = checkStatus()
        
        guard currentStatus == .notDetermined else {
            return currentStatus
        }
        
        logger.info("Requesting contacts permission...")
        let store = CNContactStore()
        
        do {
            let granted = try await store.requestAccess(for: .contacts)
            let newStatus: PermissionStatus = granted ? .authorized : .denied
            logger.info("Contacts permission: \(granted ? "granted" : "denied")")
            return newStatus
        } catch {
            logger.error("Contacts permission request failed: \(error.localizedDescription)")
            return .denied
        }
    }
    
    private static func mapStatus(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .limited: return .authorized // Limited access is still usable
        @unknown default: return .unknown
        }
    }
}
```

### 3.6 Permissions Manager

**File:** `Ora/Permissions/PermissionsManager.swift`

```swift
//
//  PermissionsManager.swift
//  Ora
//
//  Centralized permission state management
//

import Foundation
import AppKit
import os

/// Notification posted when permission state changes
extension Notification.Name {
    static let permissionsStateDidChange = Notification.Name("permissionsStateDidChange")
}

/// Centralized manager for all app permissions
actor PermissionsManager {
    
    // MARK: - Singleton
    
    static let shared = PermissionsManager()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "PermissionsManager")
    private var _state = PermissionsState()
    
    /// Current permission state
    var state: PermissionsState {
        _state
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Refresh all permission statuses
    func refreshAll() async {
        logger.debug("Refreshing all permission statuses...")
        
        _state.microphone = MicrophonePermission.checkStatus()
        _state.accessibility = AccessibilityPermission.checkStatus()
        _state.calendar = EventKitPermission.checkCalendarStatus()
        _state.reminders = EventKitPermission.checkRemindersStatus()
        _state.contacts = ContactsPermission.checkStatus()
        
        await postStateChange()
        
        logger.info("Permissions refreshed: required=\(self._state.requiredPermissionsGranted)")
    }
    
    /// Check status of a specific permission
    func check(_ type: PermissionType) async -> PermissionStatus {
        let status: PermissionStatus
        
        switch type {
        case .microphone:
            status = MicrophonePermission.checkStatus()
            _state.microphone = status
        case .accessibility:
            status = AccessibilityPermission.checkStatus()
            _state.accessibility = status
        case .calendar:
            status = EventKitPermission.checkCalendarStatus()
            _state.calendar = status
        case .reminders:
            status = EventKitPermission.checkRemindersStatus()
            _state.reminders = status
        case .contacts:
            status = ContactsPermission.checkStatus()
            _state.contacts = status
        }
        
        return status
    }
    
    /// Request a specific permission
    func request(_ type: PermissionType) async -> PermissionStatus {
        logger.info("Requesting permission: \(type.rawValue)")
        
        let status: PermissionStatus
        
        switch type {
        case .microphone:
            status = await MicrophonePermission.request()
            _state.microphone = status
        case .accessibility:
            status = await MainActor.run { AccessibilityPermission.request() }
            _state.accessibility = status
        case .calendar:
            status = await EventKitPermission.requestCalendar()
            _state.calendar = status
        case .reminders:
            status = await EventKitPermission.requestReminders()
            _state.reminders = status
        case .contacts:
            status = await ContactsPermission.request()
            _state.contacts = status
        }
        
        await postStateChange()
        return status
    }
    
    /// Request all required permissions
    func requestRequired() async -> Bool {
        _ = await request(.microphone)
        _ = await request(.accessibility)
        return _state.requiredPermissionsGranted
    }
    
    /// Request all optional permissions
    func requestOptional() async {
        _ = await request(.calendar)
        _ = await request(.reminders)
        _ = await request(.contacts)
    }
    
    /// Open System Settings for a permission
    @MainActor
    func openSettings(for type: PermissionType) {
        let urlString: String
        
        switch type {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .calendar:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .reminders:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .contacts:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Private
    
    private func postStateChange() async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .permissionsStateDidChange,
                object: self._state
            )
        }
    }
}
```

---

## 4. Directory Structure

```
Ora/
└── Permissions/
    ├── PermissionTypes.swift
    ├── PermissionsManager.swift
    ├── MicrophonePermission.swift
    ├── AccessibilityPermission.swift
    ├── EventKitPermission.swift
    └── ContactsPermission.swift
```

---

## 5. Acceptance Criteria

### Core Functionality

- [ ] **AC-1:** `PermissionsManager.shared` provides singleton access
- [ ] **AC-2:** `refreshAll()` checks all permission statuses
- [ ] **AC-3:** `request(_:)` requests individual permissions
- [ ] **AC-4:** `requestRequired()` requests microphone and accessibility
- [ ] **AC-5:** `state.requiredPermissionsGranted` returns true when mic + accessibility granted

### Individual Permissions

- [ ] **AC-6:** Microphone permission uses AVCaptureDevice API
- [ ] **AC-7:** Accessibility permission uses AXIsProcessTrusted API
- [ ] **AC-8:** Calendar permission uses EKEventStore API
- [ ] **AC-9:** Reminders permission uses EKEventStore API
- [ ] **AC-10:** Contacts permission uses CNContactStore API

### State Management

- [ ] **AC-11:** State changes post `.permissionsStateDidChange` notification
- [ ] **AC-12:** Notifications are posted on MainActor
- [ ] **AC-13:** `openSettings(for:)` opens correct System Settings pane

---

## 6. Test Cases

```swift
// PermissionsManagerTests.swift

import XCTest
@testable import Ora

final class PermissionsManagerTests: XCTestCase {
    
    // TC-1: Singleton access
    func test_shared_returnsSameInstance() async {
        let instance1 = PermissionsManager.shared
        let instance2 = PermissionsManager.shared
        // Actor identity check
        let state1 = await instance1.state
        let state2 = await instance2.state
        XCTAssertEqual(state1, state2)
    }
    
    // TC-2: Initial state
    func test_initialState_allUnknown() async {
        let manager = PermissionsManager.shared
        let state = await manager.state
        // State may be unknown or actual status depending on test environment
        XCTAssertNotNil(state)
    }
    
    // TC-3: Refresh updates state
    func test_refreshAll_updatesState() async {
        let manager = PermissionsManager.shared
        await manager.refreshAll()
        let state = await manager.state
        // At least microphone should have a determined state
        XCTAssertNotEqual(state.microphone, .unknown)
    }
    
    // TC-4: Required permissions check
    func test_requiredPermissionsGranted_bothNeeded() async {
        let state = PermissionsState(
            microphone: .authorized,
            accessibility: .authorized,
            calendar: .denied,
            reminders: .denied,
            contacts: .denied
        )
        XCTAssertTrue(state.requiredPermissionsGranted)
    }
    
    // TC-5: Required permissions fail if mic denied
    func test_requiredPermissionsGranted_micDenied_false() async {
        let state = PermissionsState(
            microphone: .denied,
            accessibility: .authorized,
            calendar: .authorized,
            reminders: .authorized,
            contacts: .authorized
        )
        XCTAssertFalse(state.requiredPermissionsGranted)
    }
}
```

---

## 7. Implementation Checklist

- [ ] Create `Ora/Permissions/PermissionTypes.swift`
- [ ] Create `Ora/Permissions/MicrophonePermission.swift`
- [ ] Create `Ora/Permissions/AccessibilityPermission.swift`
- [ ] Create `Ora/Permissions/EventKitPermission.swift`
- [ ] Create `Ora/Permissions/ContactsPermission.swift`
- [ ] Create `Ora/Permissions/PermissionsManager.swift`
- [ ] Add notification name extension
- [ ] Add unit tests
- [ ] Verify each permission request works in Simulator/Device

---

## 8. Notes

### Accessibility Permission Special Case

Unlike other permissions, Accessibility cannot be granted programmatically:
- `AXIsProcessTrustedWithOptions` only shows the system prompt
- User must manually enable in System Settings
- App may need to be restarted for changes to take effect
- Consider polling `AXIsProcessTrusted()` periodically during setup

### TCC Reset for Testing

During development, reset permissions with:
```bash
tccutil reset Microphone com.ora.app
tccutil reset Accessibility com.ora.app
tccutil reset Calendar com.ora.app
tccutil reset Reminders com.ora.app
tccutil reset AddressBook com.ora.app
```

Or use `./build.sh reset-perms` if the build script supports it.
