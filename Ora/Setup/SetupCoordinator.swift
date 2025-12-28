//
//  SetupCoordinator.swift
//  Ora
//
//  Coordinates the first-run setup flow
//

import Foundation
import SwiftUI
import os

/// Manages the first-run setup experience
@MainActor
final class SetupCoordinator: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var state = SetupState()
    @Published private(set) var isShowingSetup = false

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "SetupCoordinator")
    private let userDefaultsKey = "com.ora.setupComplete"
    private var setupWindow: NSWindow?
    private var downloadTask: Task<Void, Never>?

    // MARK: - Singleton

    static let shared = SetupCoordinator()

    // MARK: - Initialization

    private override init() {
        super.init()
        self.loadSystemInfo()
    }

    // MARK: - Public API

    /// Check if setup is needed and show if required
    func checkAndShowSetupIfNeeded() {
        let isComplete = UserDefaults.standard.bool(forKey: self.userDefaultsKey)

        if isComplete {
            // Verify models are still available
            Task {
                let modelsReady = await ModelManager.shared.requiredModelsAvailable()
                if !modelsReady {
                    self.logger.warning("Setup was complete but models missing, restarting setup")
                    self.state.currentStep = .download
                    self.showSetup()
                    // Start downloads automatically when resuming to download step
                    await self.startDownloads()
                }
            }
        } else {
            self.showSetup()
        }
    }

    /// Returns true if setup has been completed
    var isSetupComplete: Bool {
        UserDefaults.standard.bool(forKey: self.userDefaultsKey)
    }

    /// Show the setup window
    func showSetup() {
        self.isShowingSetup = true
        self.logger.info("Showing setup window at step: \(self.state.currentStep.title)")

        // Create and show the window
        if self.setupWindow == nil {
            let contentView = SetupWindow(coordinator: self)
            let hostingController = NSHostingController(rootView: contentView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Welcome to Ora"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()

            // Prevent closing while downloads are in progress
            window.delegate = self

            self.setupWindow = window
        }

        self.setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dismiss setup (only when complete)
    func dismissSetup() {
        guard self.state.isComplete else {
            self.logger.warning("Cannot dismiss setup before completion")
            return
        }
        self.isShowingSetup = false
        self.setupWindow?.close()
        self.setupWindow = nil
    }

    /// Move to next step
    func nextStep() async {
        switch self.state.currentStep {
        case .welcome:
            self.state.currentStep = .permissions
            await self.refreshPermissionsState()

        case .permissions:
            // Validate required permissions
            let permState = await PermissionsManager.shared.state
            if permState.requiredPermissionsGranted {
                self.state.permissionsGranted = true
                self.state.currentStep = .download
                // Start downloads automatically
                await self.startDownloads()
            } else {
                self.logger.warning("Required permissions not granted")
            }

        case .download:
            // Only proceed if downloads complete
            let modelsReady = await ModelManager.shared.requiredModelsAvailable()
            if modelsReady {
                self.state.currentStep = .ready
            }

        case .ready:
            self.completeSetup()
        }
    }

    /// Go back to previous step
    func previousStep() {
        guard self.state.currentStep.canGoBack else { return }

        if let previousIndex = SetupStep(rawValue: self.state.currentStep.rawValue - 1) {
            self.state.currentStep = previousIndex
        }
    }

    /// Request a specific permission
    func requestPermission(_ type: PermissionType) async {
        _ = await PermissionsManager.shared.request(type)
        await self.refreshPermissionsState()
    }

    /// Request all required permissions
    func requestRequiredPermissions() async {
        _ = await PermissionsManager.shared.requestRequired()
        await self.refreshPermissionsState()
    }

    /// Retry failed download
    func retryDownload() async {
        self.state.downloadError = nil
        await self.startDownloads()
    }

    /// Postpone setup (show minimal UI)
    func postponeSetup() {
        self.isShowingSetup = false
        self.setupWindow?.close()
        // App remains in limited state until setup completes
        self.logger.info("Setup postponed by user")
    }

    /// Cancel any in-progress downloads
    func cancelDownloads() {
        self.downloadTask?.cancel()
        self.downloadTask = nil
    }

    /// Update permissions granted state (called from PermissionsStepView)
    func updatePermissionsGranted(_ granted: Bool) {
        self.state.permissionsGranted = granted
    }

    // MARK: - Private

    private func loadSystemInfo() {
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        self.state.systemRAMGB = Int(ramBytes / (1024 * 1024 * 1024))

        let recommendedLLM: ModelIdentifier = self.state.systemRAMGB >= 16 ? .qwen7B : .qwen3B
        self.state.recommendedModel = recommendedLLM.displayName
    }

    private func refreshPermissionsState() async {
        await PermissionsManager.shared.refreshAll()
        let permState = await PermissionsManager.shared.state
        self.state.permissionsGranted = permState.requiredPermissionsGranted
    }

    private func startDownloads() async {
        await self.ensurePrimaryLLMSelected()
        self.state.downloadProgress = 0
        self.state.downloadError = nil
        self.state.modelProgresses = [:]

        // Start the download in a tracked task for cancellation support
        self.downloadTask = Task { @MainActor in
            do {
                try await ModelManager.shared.downloadRequiredModels { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.state.downloadProgress = progress.overallProgress

                        // Track individual model progress
                        for (model, modelProgress) in progress.models {
                            self.state.modelProgresses[model] = modelProgress.progress
                            if modelProgress.progress < 1.0 && modelProgress.progress > 0 {
                                self.state.downloadingModel = model.displayName
                            }
                        }
                    }
                }

                self.state.downloadProgress = 1.0
                self.state.downloadingModel = nil
                self.logger.info("All downloads complete")

                // Auto-advance to ready
                self.state.currentStep = .ready

            } catch {
                if !Task.isCancelled {
                    self.state.downloadError = error.localizedDescription
                    self.logger.error("Download failed: \(error.localizedDescription)")
                }
            }
        }

        await self.downloadTask?.value
    }

    private func ensurePrimaryLLMSelected() async {
        let hasPersistedPrimary = await self.hasPersistedPrimaryLLM()
        guard !hasPersistedPrimary else { return }
        let recommendedLLM: ModelIdentifier = self.state.systemRAMGB >= 16 ? .qwen7B : .qwen3B
        await ModelManager.shared.setPrimaryLLM(recommendedLLM)
    }

    private func hasPersistedPrimaryLLM() async -> Bool {
        await Task.detached {
            let url = ModelPaths.metadataFile
            guard let data = try? Data(contentsOf: url) else { return false }
            let decoder = JSONDecoder()
            guard let metadata = try? decoder.decode([PersistedModelMetadata].self, from: data) else { return false }
            return metadata.contains { $0.isPrimary && $0.identifier.category == .llm }
        }.value
    }

    private func completeSetup() {
        self.state.isComplete = true
        UserDefaults.standard.set(true, forKey: self.userDefaultsKey)
        self.isShowingSetup = false
        self.setupWindow?.close()
        self.setupWindow = nil
        self.logger.info("Setup completed successfully")

        // Notify app that setup is done
        NotificationCenter.default.post(name: .setupDidComplete, object: nil)
    }
}

private struct PersistedModelMetadata: Decodable {
    let identifier: ModelIdentifier
    let isPrimary: Bool
}

// MARK: - NSWindowDelegate

extension SetupCoordinator: NSWindowDelegate {
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Allow closing only if not in download step or if downloads are complete
        MainActor.assumeIsolated {
            if self.state.currentStep == .download && self.state.downloadProgress < 1.0 {
                // Don't allow closing during active downloads
                return false
            }
            return true
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if !self.state.isComplete {
                // User closed window without completing - postpone
                self.isShowingSetup = false
                self.logger.info("Setup window closed without completion")
            }
        }
    }
}
