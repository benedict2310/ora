//
//  AppDelegate.swift
//  Ora
//
//  Main application delegate
//

import AppKit
import MLX
import UserNotifications
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    /// Status bar controller (exposed for StatusBarController.shared access)
    private(set) var statusBarController: StatusBarController?
    private let logger = Logger.ora(category: "AppDelegate")
    private var setupObserver: NSObjectProtocol?
    private var hotkeyPressObserver: NSObjectProtocol?
    private var hotkeyReleaseObserver: NSObjectProtocol?
    private var memoryFileWatcher: MemoryFileWatcher?
    private var backgroundTaskManager: BackgroundTaskManager?
    private var taskNotificationDelegate: TaskNotificationDelegate?
    // Sparkle/updates are not relevant for unit tests and can cause hangs in headless CI.
    private lazy var updateController = UpdateController.shared

    private static var isRunningUnitTests: Bool {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isRunningUnitTests {
            self.logger.info("XCTest detected - skipping app launch initialization")
            return
        }

        self.logger.info("Ora launching...")

        // Register notification categories and delegate early so
        // background-task notifications are handled from first launch.
        let notificationDelegate = TaskNotificationDelegate()
        self.taskNotificationDelegate = notificationDelegate
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = notificationDelegate
        TaskNotificationService.registerCategories(on: notificationCenter)

        do {
            try MemoryFileManager.ensureDirectories()
        } catch {
            self.logger.warning("Failed to initialize on-disk memory folder: \(error.localizedDescription)")
        }

        Task.detached(priority: .utility) {
            await MemoryIndex.shared.rebuild()
        }

        // Initialize persistence
        _ = PersistenceManager.shared

        // Build skills index in the background at startup
        Task.detached(priority: .utility) {
            await SkillStore.shared.rebuildIndex()
        }

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

        // Clean up old data (audit log, expired sessions) to prevent unbounded growth
        let cleanup = PersistenceManager.shared.cleanupOldData()
        if cleanup.auditEntriesDeleted > 0 || cleanup.sessionsDeleted > 0 {
            self.logger.info("Startup cleanup: \(cleanup.auditEntriesDeleted) audit entries, \(cleanup.sessionsDeleted) sessions removed")
        }

        // Register cloud LLM provider factories
        Task {
            let anthropicModel = UserDefaults.standard.selectedAnthropicModel
            let openAIModelIdentifier = UserDefaults.standard.selectedOpenAIModelIdentifier
            await CodexOAuthManager.shared.importCLIAuthIfNeeded()

            await LLMProviderManager.shared.register(
                factory: AnthropicProviderFactory(model: anthropicModel.rawValue),
                for: .anthropic
            )
            await LLMProviderManager.shared.register(
                factory: OpenAIProviderFactory(model: openAIModelIdentifier),
                for: .openai
            )
            await LLMProviderManager.shared.restoreSelectedProviderIfNeeded()
            self.logger.info("Cloud provider factories registered")
        }

        // Register default tools (calendar, etc.) for the agent loop
        Task {
            await ToolRegistry.shared.registerDefaultToolsIfNeeded()
            self.logger.info("Default tools registered")
        }

        Task {
            await ModelMigrationCoordinator.shared.runIfNeeded()
        }

        self.backgroundTaskManager = PersistenceManager.shared.backgroundTaskManager
        if let backgroundTaskManager = self.backgroundTaskManager {
            Task {
                await backgroundTaskManager.recoverUnfinishedTasksOnLaunch()
                self.logger.info("Background task manager reconciled stale tasks")
            }
        }

        Task {
            let cutoffDate = Date().addingTimeInterval(-ArtifactStore.defaultCleanupAge)
            let removedCount = await ArtifactStore.shared.cleanup(olderThan: cutoffDate)
            if removedCount > 0 {
                self.logger.info("Artifact cleanup removed \(removedCount) expired task folders")
            }
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
        self.startMemoryFileWatcher()
    }

    private func startMemoryFileWatcher() {
        let fileURL = MemoryFileManager().memoryFileURL
        let watcher = MemoryFileWatcher(fileURL: fileURL) {
            await MemoryIndex.shared.rebuild()
        }
        self.memoryFileWatcher = watcher

        Task {
            await watcher.startWatching()
        }
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

        // Clear pending and delivered notifications
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()

        if let watcher = self.memoryFileWatcher {
            Task { await watcher.stopWatching() }
        }
        if let backgroundTaskManager = self.backgroundTaskManager {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await backgroundTaskManager.cancelAll()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
        }
        PersistenceManager.shared.flushSave()

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
