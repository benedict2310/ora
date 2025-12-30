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
    private var currentSessionTask: Task<Void, Never>?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.logger.info("Ora launching...")

        // Initialize persistence
        _ = PersistenceManager.shared

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

        // Check if setup is needed (async to wait for model verification)
        Task { @MainActor in
            let setupNeeded = await SetupCoordinator.shared.checkAndShowSetupIfNeeded()
            if !setupNeeded {
                // Setup was already complete and models are ready
                self.onSetupComplete()
            }
            // If setup is needed, onSetupComplete will be called via notification when user completes setup
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

        // Cancel any previous session task to prevent race conditions
        self.currentSessionTask?.cancel()

        // Start the transcription session
        self.currentSessionTask = Task {
            do {
                let transcript = try await TranscriptCoordinator.shared.startSession()

                // Session completed - log the result
                if let transcript = transcript, !transcript.isEmpty {
                    self.logger.info("Final transcript: \(transcript.prefix(100))...")
                }

                // Transition to completed state (no orchestration handoff yet)
                self.statusBarController?.setState(.idle)
                OverlayWindowController.shared.mode = .completed
                OverlayWindowController.shared.scheduleAutoDismiss()

            } catch {
                // Check if this was just a cancellation (rapid press/release)
                if Task.isCancelled {
                    self.logger.debug("Session was cancelled")
                    return
                }

                self.logger.error("Failed to start session: \(error.localizedDescription)")

                // Show error in UI so user knows why it failed
                self.statusBarController?.setState(.error(error.localizedDescription))
                OverlayWindowController.shared.mode = .error(error.localizedDescription)
            }
        }
    }

    private func onHotkeyRelease() {
        self.logger.debug("Hotkey released - end PTT")
        self.statusBarController?.setState(.thinking)

        // Update overlay mode to thinking
        OverlayWindowController.shared.mode = .thinking

        // Stop the session - this triggers ASR finalization
        // The session task will complete in onHotkeyPress() and handle the result
        Task {
            await TranscriptCoordinator.shared.stopSession()
        }
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
