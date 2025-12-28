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
        // Use raw string key to avoid Swift 6 concurrency issues with the global constant
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
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
