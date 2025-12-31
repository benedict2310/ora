//
//  HotkeyManager.swift
//  Ora
//
//  Global hotkey registration using Carbon Event APIs for Push-to-Talk
//

import AppKit
import Carbon
import os

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the hotkey is pressed down (start PTT)
    static let hotkeyDidPress = Notification.Name("hotkeyDidPress")

    /// Posted when the hotkey is released (end PTT)
    static let hotkeyDidRelease = Notification.Name("hotkeyDidRelease")
}

// MARK: - Hotkey Manager

/// Manages global hotkey registration using Carbon Event APIs.
///
/// Carbon Events are the only reliable way to register global hotkeys on macOS.
/// NSEvent monitors are unreliable and don't fire consistently when the app is not focused.
@MainActor
final class HotkeyManager {

    // MARK: - Singleton

    static let shared = HotkeyManager()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "HotkeyManager")
    private var configuration: HotkeyConfiguration

    /// Carbon event handler reference
    private var eventHandler: EventHandlerRef?

    /// Registered hotkey reference (for unregistration)
    private var hotkeyRef: EventHotKeyRef?

    /// Unique hotkey ID
    private var hotkeyID: UInt32 = 1

    /// Whether the hotkey is currently pressed (for PTT state)
    private var isHotkeyDown = false

    /// Whether the manager is currently listening
    private var isEnabled = false

    /// App signature for Carbon (4-char code)
    private let appSignature: OSType = {
        // "ORAP" = Ora PTT
        let chars: [UInt8] = [0x4F, 0x52, 0x41, 0x50]  // O, R, A, P
        return OSType(chars[0]) << 24 | OSType(chars[1]) << 16 | OSType(chars[2]) << 8 | OSType(chars[3])
    }()

    /// Current hotkey configuration
    var currentHotkey: HotkeyConfiguration {
        self.configuration
    }

    /// Whether the hotkey is currently being held
    var isPressed: Bool {
        self.isHotkeyDown
    }

    /// Whether the manager is currently listening for events
    var isListening: Bool {
        self.isEnabled
    }

    // MARK: - Initialization

    private init() {
        self.configuration = HotkeyConfiguration.load()
    }

    // MARK: - Public API

    /// Start listening for hotkey events using Carbon Event APIs
    func start() {
        guard !self.isEnabled else {
            self.logger.debug("Hotkey manager already started")
            return
        }

        // Install Carbon event handler first
        self.installEventHandler()

        // Register the configured hotkey
        self.registerHotkey()

        self.isEnabled = true
        self.logger.info("Hotkey manager started, listening for \(self.configuration.displayString)")
    }

    /// Stop listening for hotkey events
    func stop() {
        guard self.isEnabled else { return }

        // Unregister hotkey
        self.unregisterHotkey()

        // Remove event handler
        self.removeEventHandler()

        // Reset state
        self.isHotkeyDown = false
        self.isEnabled = false
        self.logger.info("Hotkey manager stopped")
    }

    /// Update hotkey configuration
    /// - Parameter config: The new hotkey configuration
    func setHotkey(_ config: HotkeyConfiguration) {
        let wasEnabled = self.isEnabled

        if wasEnabled {
            self.stop()
        }

        self.configuration = config
        self.configuration.save()
        self.logger.info("Hotkey updated to \(config.displayString)")

        if wasEnabled {
            self.start()
        }
    }

    /// Reset to default hotkey (Option + Space)
    func resetToDefault() {
        self.setHotkey(.defaultHotkey)
    }

    /// Check if a hotkey configuration conflicts with known system shortcuts
    /// - Parameter config: The configuration to check
    /// - Returns: True if the configuration conflicts with a system shortcut
    func checkForConflicts(_ config: HotkeyConfiguration) -> Bool {
        // Known system shortcuts to avoid
        let conflicts: [(keyCode: UInt16, modifiers: UInt32)] = [
            // Spotlight: Cmd+Space
            (UInt16(kVK_Space), UInt32(cmdKey)),
            // Screenshot: Cmd+Shift+3, Cmd+Shift+4, Cmd+Shift+5
            (UInt16(kVK_ANSI_3), UInt32(cmdKey | shiftKey)),
            (UInt16(kVK_ANSI_4), UInt32(cmdKey | shiftKey)),
            (UInt16(kVK_ANSI_5), UInt32(cmdKey | shiftKey)),
            // App Switcher: Cmd+Tab
            (UInt16(kVK_Tab), UInt32(cmdKey)),
            // Quit: Cmd+Q
            (UInt16(kVK_ANSI_Q), UInt32(cmdKey)),
            // Close Window: Cmd+W
            (UInt16(kVK_ANSI_W), UInt32(cmdKey)),
            // Hide: Cmd+H
            (UInt16(kVK_ANSI_H), UInt32(cmdKey)),
            // Minimize: Cmd+M
            (UInt16(kVK_ANSI_M), UInt32(cmdKey)),
        ]

        for conflict in conflicts {
            if config.keyCode == conflict.keyCode && config.modifiers == conflict.modifiers {
                return true
            }
        }

        return false
    }

    // MARK: - Private: Carbon Event Handler

    private func installEventHandler() {
        // Define event types we want to handle
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        // Create callback - must be a C function pointer
        let callback: EventHandlerUPP = { (_, theEvent, userData) -> OSStatus in
            guard let userData = userData else {
                return OSStatus(eventNotHandledErr)
            }

            // Get hotkey ID from event
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

            guard status == noErr else {
                return status
            }

            // Get event kind to determine press vs release
            let eventKind = GetEventKind(theEvent)

            // Get manager reference
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            // Dispatch to main actor
            Task { @MainActor in
                manager.handleHotkeyEvent(id: hotkeyID.id, isPressed: eventKind == UInt32(kEventHotKeyPressed))
            }

            return noErr
        }

        // Install handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &self.eventHandler
        )

        if status != noErr {
            self.logger.error("Failed to install Carbon event handler: \(status)")
        }
    }

    private func removeEventHandler() {
        if let handler = self.eventHandler {
            RemoveEventHandler(handler)
            self.eventHandler = nil
        }
    }

    private func registerHotkey() {
        var eventHotkey: EventHotKeyRef?

        let hotkeyIDStruct = EventHotKeyID(signature: self.appSignature, id: self.hotkeyID)

        let status = RegisterEventHotKey(
            UInt32(self.configuration.keyCode),
            self.configuration.modifiers,
            hotkeyIDStruct,
            GetEventDispatcherTarget(),
            0,
            &eventHotkey
        )

        if status == noErr, let hotkey = eventHotkey {
            self.hotkeyRef = hotkey
            self.logger.debug("Registered hotkey with ID \(self.hotkeyID)")
        } else {
            self.logger.error("Failed to register hotkey: status=\(status)")
        }
    }

    private func unregisterHotkey() {
        if let hotkey = self.hotkeyRef {
            UnregisterEventHotKey(hotkey)
            self.hotkeyRef = nil
            self.logger.debug("Unregistered hotkey")
        }
    }

    // MARK: - Private: Event Handling

    private func handleHotkeyEvent(id: UInt32, isPressed: Bool) {
        // Verify this is our hotkey
        guard id == self.hotkeyID else { return }

        if isPressed {
            // Ignore if already pressed (debounce)
            guard !self.isHotkeyDown else { return }

            self.isHotkeyDown = true
            self.logger.debug("Hotkey pressed")
            NotificationCenter.default.post(name: .hotkeyDidPress, object: nil)
        } else {
            // Ignore if not pressed
            guard self.isHotkeyDown else { return }

            self.isHotkeyDown = false
            self.logger.debug("Hotkey released")
            NotificationCenter.default.post(name: .hotkeyDidRelease, object: nil)
        }
    }
}

// MARK: - NSEvent.ModifierFlags Extension

extension NSEvent.ModifierFlags {
    /// Convert to Carbon modifier flags
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if self.contains(.control) { flags |= UInt32(controlKey) }
        if self.contains(.option) { flags |= UInt32(optionKey) }
        if self.contains(.shift) { flags |= UInt32(shiftKey) }
        if self.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }
}
