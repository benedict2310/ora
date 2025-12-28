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

        self.logger.info("Ora ready")
    }

    private func onSetupComplete() {
        self.logger.info("Setup complete, initializing main functionality")
        // Initialize hotkey, warmup models, etc.
        // This will be expanded in future stories
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.logger.info("Ora terminating...")
        self.statusBarController?.shutdown()

        // Clean up observer
        if let observer = self.setupObserver {
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
