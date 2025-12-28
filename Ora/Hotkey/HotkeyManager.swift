//
//  HotkeyManager.swift
//  Ora
//
//  Global hotkey registration and event handling for Push-to-Talk
//

import AppKit
import Carbon.HIToolbox
import os

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the hotkey is pressed down (start PTT)
    static let hotkeyDidPress = Notification.Name("hotkeyDidPress")

    /// Posted when the hotkey is released (end PTT)
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
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isHotkeyDown = false
    private var isEnabled = false

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

    /// Start listening for hotkey events
    /// - Note: Requires accessibility permission to work
    func start() {
        guard !self.isEnabled else {
            self.logger.debug("Hotkey manager already started")
            return
        }

        // Check accessibility permission
        guard AXIsProcessTrusted() else {
            self.logger.error("Cannot start hotkey manager: Accessibility permission not granted")
            return
        }

        // Register global event monitor for events outside our app
        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }

        // Register local event monitor for events inside our app
        self.localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
            return event
        }

        self.isEnabled = true
        self.logger.info("Hotkey manager started, listening for \(self.configuration.displayString)")
    }

    /// Stop listening for hotkey events
    func stop() {
        guard self.isEnabled else { return }

        if let monitor = self.globalMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMonitor = nil
        }

        if let monitor = self.localMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMonitor = nil
        }

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

    // MARK: - Private: Event Handling

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            self.handleKeyDown(event)
        case .keyUp:
            self.handleKeyUp(event)
        case .flagsChanged:
            self.handleFlagsChanged(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Ignore repeated events
        guard !event.isARepeat else { return }

        // Check if this is our hotkey
        guard self.matchesHotkey(event) else { return }

        // Ignore if already pressed
        guard !self.isHotkeyDown else { return }

        self.isHotkeyDown = true
        self.logger.debug("Hotkey pressed")
        NotificationCenter.default.post(name: .hotkeyDidPress, object: nil)
    }

    private func handleKeyUp(_ event: NSEvent) {
        // Only handle if hotkey is currently pressed
        guard self.isHotkeyDown else { return }

        // Check if this is our key (ignore modifiers for key up)
        guard event.keyCode == self.configuration.keyCode else { return }

        self.isHotkeyDown = false
        self.logger.debug("Hotkey released")
        NotificationCenter.default.post(name: .hotkeyDidRelease, object: nil)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Handle case where modifier is released before key
        // If we're holding the hotkey and the required modifiers are no longer present,
        // treat this as a release
        guard self.isHotkeyDown else { return }

        let modifiers = event.modifierFlags.carbonFlags
        let requiredModifiers = self.configuration.modifiers

        // If required modifiers are no longer held, treat as release
        if (modifiers & requiredModifiers) != requiredModifiers {
            self.isHotkeyDown = false
            self.logger.debug("Hotkey released (modifier released)")
            NotificationCenter.default.post(name: .hotkeyDidRelease, object: nil)
        }
    }

    private func matchesHotkey(_ event: NSEvent) -> Bool {
        // Check key code matches
        guard event.keyCode == self.configuration.keyCode else {
            return false
        }

        // Check that required modifiers are present
        let modifiers = event.modifierFlags.carbonFlags
        let requiredModifiers = self.configuration.modifiers

        return (modifiers & requiredModifiers) == requiredModifiers
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
