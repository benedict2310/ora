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
    private var setupObserver: NSObjectProtocol?
    private var hotkeyPressObserver: NSObjectProtocol?
    private var hotkeyReleaseObserver: NSObjectProtocol?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.logger.info("Ora launching...")

        // Initialize status bar
        self.statusBarController = StatusBarController()

        // Set activation policy (accessory = menu bar only)
        NSApp.setActivationPolicy(.accessory)

        // Listen for setup completion
        self.setupObserver = NotificationCenter.default.addObserver(
            forName: .setupDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onSetupComplete()
        }

        // Check if setup is needed
        SetupCoordinator.shared.checkAndShowSetupIfNeeded()

        // If setup was already complete, start immediately
        if SetupCoordinator.shared.isSetupComplete {
            self.onSetupComplete()
        }

        self.logger.info("Ora ready")
    }

    private func onSetupComplete() {
        self.logger.info("Setup complete, initializing main functionality")
        self.startHotkeyManager()
    }

    private func startHotkeyManager() {
        // Start the hotkey manager (Carbon Events don't require accessibility permission)
        HotkeyManager.shared.start()

        // Listen for hotkey events
        self.hotkeyPressObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyDidPress,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onHotkeyPress()
        }

        self.hotkeyReleaseObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyDidRelease,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onHotkeyRelease()
        }

        self.logger.info("Hotkey manager started with: \(HotkeyManager.shared.currentHotkey.displayString)")
    }

    private func onHotkeyPress() {
        self.logger.debug("Hotkey pressed - start PTT")
        self.statusBarController?.setState(.listening)

        // Show overlay and set to listening mode
        OverlayWindowController.shared.mode = .listening
        OverlayWindowController.shared.show()
    }

    private func onHotkeyRelease() {
        self.logger.debug("Hotkey released - end PTT")
        self.statusBarController?.setState(.thinking)

        // Update overlay mode to thinking
        OverlayWindowController.shared.mode = .thinking
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.logger.info("Ora terminating...")

        // Stop hotkey manager
        HotkeyManager.shared.stop()

        // Hide overlay
        OverlayWindowController.shared.hide(animated: false)

        self.statusBarController?.shutdown()

        // Clean up observers
        if let observer = self.setupObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.hotkeyPressObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.hotkeyReleaseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Only show preferences if no windows are visible
        // This avoids surprising UX when user expects to see existing windows
        if !flag {
            self.statusBarController?.showPreferences()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
