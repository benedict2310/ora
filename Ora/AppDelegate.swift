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
        self.logger.info("Ora launching...")

        // Initialize status bar
        self.statusBarController = StatusBarController()

        // Set activation policy (accessory = menu bar only)
        NSApp.setActivationPolicy(.accessory)

        self.logger.info("Ora ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.logger.info("Ora terminating...")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If user clicks dock icon (if visible), show preferences or activate
        self.statusBarController?.showPreferences()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
