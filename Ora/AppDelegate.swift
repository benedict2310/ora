//
//  AppDelegate.swift
//  Ora
//
//  Main application delegate
//

import AppKit
import MLX
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    /// Status bar controller (exposed for StatusBarController.shared access)
    private(set) var statusBarController: StatusBarController?
    private let logger = Logger(subsystem: "com.ora.app", category: "AppDelegate")
    private var setupObserver: NSObjectProtocol?
    private var hotkeyPressObserver: NSObjectProtocol?
    private var hotkeyReleaseObserver: NSObjectProtocol?
    private let updateController = UpdateController.shared

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.logger.info("Ora launching...")

        // Initialize persistence
        _ = PersistenceManager.shared

        // Initialize status bar
        self.statusBarController = StatusBarController()

        // Initialize Sparkle updater
        _ = self.updateController

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

        // Register default tools (calendar, etc.) for the agent loop
        Task {
            await ToolRegistry.shared.registerDefaultToolsIfNeeded()
            self.logger.info("Default tools registered")
        }

        // Start preloading models in the background
        Task {
            do {
                try await ASRService.shared.prepare()
                self.logger.info("ASR service prepared")
            } catch {
                self.logger.error("Failed to prepare ASR service: \(error.localizedDescription)")
            }
        }

        // Prepare TTS engine for faster first response
        Task {
            do {
                try await TTSService.shared.prepare()
                self.logger.info("TTS service prepared")
            } catch {
                self.logger.warning("TTS preparation failed: \(error.localizedDescription)")
            }
        }

        // Prepare audio playback engine
        Task {
            do {
                try await AudioPlaybackService.shared.prepare()
                self.logger.info("Audio playback service prepared")
            } catch {
                self.logger.warning("Audio playback preparation failed: \(error.localizedDescription)")
            }
        }

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

        self.logger.info("Hotkey manager started with: \(HotkeyManager.shared.currentHotkey.displayString)")
    }

    private func onHotkeyPress() {
        self.logger.debug("Hotkey pressed - toggle listening")
        
        // Delegate to SimplePipelineController for full ASR → LLM flow
        SimplePipelineController.shared.startListening()
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
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Clear GPU cache when app goes to background (M.02 optimization)
        // This frees Metal buffers while the app isn't being used,
        // reducing memory footprint during background.
        self.logger.debug("App resigned active - clearing GPU cache")
        GPU.clearCache()
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
