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

    // Download speed tracking
    private var downloadSpeedSamples: [Double] = []
    private var lastProgressUpdateTime: Date?
    private var lastBytesDownloaded: Int64 = 0
    private let maxSpeedSamples = 5 // Rolling average window

    // MARK: - Singleton

    static let shared = SetupCoordinator()

#if DEBUG
    static func makeForTesting(state: SetupState) -> SetupCoordinator {
        let coordinator = SetupCoordinator()
        coordinator.state = state
        return coordinator
    }
#endif

    // MARK: - Initialization

    private override init() {
        super.init()
        self.loadSystemInfo()
    }

    // MARK: - Public API

    /// Check if setup is needed and show if required
    /// - Returns: `true` if setup is needed and was shown, `false` if setup was already complete and models are available
    func checkAndShowSetupIfNeeded() async -> Bool {
        let isComplete = UserDefaults.standard.bool(forKey: self.userDefaultsKey)

        if isComplete {
            // Verify models are still available
            let modelsReady = await ModelManager.shared.requiredModelsAvailable()
            if !modelsReady {
                self.logger.warning("Setup was complete but models missing, showing model explanation")
                // Go to model explanation step so user can choose to re-download
                self.state.currentStep = .modelExplanation
                self.showSetup()
                return true  // Setup is needed
            }
            return false  // Setup not needed, models ready
        } else {
            self.showSetup()
            return true  // Setup is needed
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
            // Validate required permissions before proceeding to model explanation
            let permState = await PermissionsManager.shared.state
            if permState.requiredPermissionsGranted {
                self.state.permissionsGranted = true
                self.state.currentStep = .modelExplanation
            } else {
                self.logger.warning("Required permissions not granted")
            }

        case .modelExplanation:
            // This step doesn't auto-advance; user must click "Download Now"
            break

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

    /// Start downloads from the model explanation step (user clicked "Download Now")
    func startDownloadFromExplanation() async {
        guard self.state.currentStep == .modelExplanation else {
            self.logger.warning("startDownloadFromExplanation called from wrong step: \(self.state.currentStep.title)")
            return
        }
        self.state.currentStep = .download
        self.state.downloadWasCancelled = false
        await self.startDownloads()
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

    /// Cancel any in-progress downloads and return to model explanation step
    func cancelDownloads() {
        self.downloadTask?.cancel()
        self.downloadTask = nil
        self.state.downloadWasCancelled = true
        self.state.isDownloading = false
        self.state.downloadError = nil
        self.state.downloadProgress = 0
        self.state.modelDownloadStates = [:]
        self.state.totalBytesDownloaded = 0
        self.state.downloadSpeedBytesPerSecond = 0
        self.state.estimatedTimeRemainingSeconds = nil
        self.resetSpeedTracking()

        // Return to model explanation step
        self.state.currentStep = .modelExplanation
        self.logger.info("Download cancelled, returning to model explanation")
    }

    /// Update permissions granted state (called from PermissionsStepView)
    func updatePermissionsGranted(_ granted: Bool) {
        self.state.permissionsGranted = granted
    }

    // MARK: - Private

    private func loadSystemInfo() {
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        self.state.systemRAMGB = Int(ramBytes / (1024 * 1024 * 1024))

        // Qwen 3 4B is the only active LLM now
        let recommendedLLM: ModelIdentifier = .qwen3_4B
        self.state.recommendedModel = recommendedLLM.displayName
        self.state.primaryLLM = recommendedLLM  // Initial default, may be updated by ensurePrimaryLLMSelected
    }

    private func refreshPermissionsState() async {
        await PermissionsManager.shared.refreshAll()
        let permState = await PermissionsManager.shared.state
        self.state.permissionsGranted = permState.requiredPermissionsGranted
    }

    private func startDownloads() async {
        await self.ensurePrimaryLLMSelected()

        // Reset download state
        self.state.downloadProgress = 0
        self.state.downloadError = nil
        self.state.modelProgresses = [:]
        self.state.isDownloading = true
        self.state.modelDownloadStates = [:]
        self.state.totalBytesDownloaded = 0
        self.state.downloadSpeedBytesPerSecond = 0
        self.state.estimatedTimeRemainingSeconds = nil
        self.resetSpeedTracking()

        // Calculate total bytes to download
        let modelsToDownload: [ModelIdentifier] = [.parakeetTDT, self.state.primaryLLM, .kokoro]
        self.state.totalBytesToDownload = modelsToDownload.reduce(0) { $0 + $1.estimatedSizeBytes }

        // Initialize all models as pending
        for model in modelsToDownload {
            self.state.modelDownloadStates[model] = .pending
        }

        // Check which models are already downloaded
        await self.initializeAlreadyDownloadedModels(modelsToDownload)

        // Start the download in a tracked task for cancellation support
        self.downloadTask = Task { @MainActor in
            do {
                try await ModelManager.shared.downloadRequiredModels { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.state.downloadProgress = progress.overallProgress

                        // Track bytes downloaded and calculate speed
                        var totalBytesNow: Int64 = 0

                        // Track individual model progress
                        for (model, modelProgress) in progress.models {
                            self.state.modelProgresses[model] = modelProgress.progress
                            totalBytesNow += modelProgress.bytesDownloaded

                            // Update model download state
                            if modelProgress.progress >= 1.0 {
                                self.state.modelDownloadStates[model] = .complete
                            } else if modelProgress.progress > 0 {
                                self.state.modelDownloadStates[model] = .downloading(
                                    progress: modelProgress.progress,
                                    bytesDownloaded: modelProgress.bytesDownloaded,
                                    totalBytes: modelProgress.totalBytes
                                )
                                self.state.downloadingModel = model.displayName
                            }
                        }

                        // Update total bytes and calculate speed/ETA
                        self.state.totalBytesDownloaded = totalBytesNow
                        self.updateDownloadSpeed(currentBytes: totalBytesNow)
                    }
                }

                self.state.downloadProgress = 1.0
                self.state.downloadingModel = nil
                self.state.isDownloading = false

                // Mark all models as complete
                for model in modelsToDownload {
                    self.state.modelDownloadStates[model] = .complete
                }

                self.logger.info("All downloads complete")

                // Auto-advance to ready
                self.state.currentStep = .ready

            } catch {
                self.state.isDownloading = false
                if !Task.isCancelled {
                    self.state.downloadError = error.localizedDescription
                    self.logger.error("Download failed: \(error.localizedDescription)")

                    // Mark current downloading model as error
                    if let currentModel = self.state.downloadingModel {
                        for model in modelsToDownload where model.displayName == currentModel {
                            self.state.modelDownloadStates[model] = .error(error.localizedDescription)
                        }
                    }
                }
            }
        }

        await self.downloadTask?.value
    }

    /// Check which models are already downloaded and mark them as complete
    private func initializeAlreadyDownloadedModels(_ models: [ModelIdentifier]) async {
        for model in models {
            if ModelPaths.modelExists(model) {
                self.state.modelDownloadStates[model] = .complete
                self.state.modelProgresses[model] = 1.0
                // Add to total bytes downloaded
                self.state.totalBytesDownloaded += model.estimatedSizeBytes
            }
        }
        // Update overall progress based on already downloaded models
        if self.state.totalBytesToDownload > 0 {
            self.state.downloadProgress = Double(self.state.totalBytesDownloaded) / Double(self.state.totalBytesToDownload)
        }
    }

    private func resetSpeedTracking() {
        self.downloadSpeedSamples = []
        self.lastProgressUpdateTime = nil
        self.lastBytesDownloaded = 0
    }

    private func updateDownloadSpeed(currentBytes: Int64) {
        let now = Date()

        guard let lastTime = self.lastProgressUpdateTime else {
            self.lastProgressUpdateTime = now
            self.lastBytesDownloaded = currentBytes
            return
        }

        let timeDelta = now.timeIntervalSince(lastTime)
        guard timeDelta > 0.1 else { return } // Throttle updates

        let bytesDelta = currentBytes - self.lastBytesDownloaded
        guard bytesDelta > 0 else { return }

        let speed = Double(bytesDelta) / timeDelta

        // Add to rolling average
        self.downloadSpeedSamples.append(speed)
        if self.downloadSpeedSamples.count > self.maxSpeedSamples {
            self.downloadSpeedSamples.removeFirst()
        }

        // Calculate average speed
        let averageSpeed = self.downloadSpeedSamples.reduce(0, +) / Double(self.downloadSpeedSamples.count)
        self.state.downloadSpeedBytesPerSecond = averageSpeed

        // Calculate ETA
        let remainingBytes = self.state.totalBytesToDownload - currentBytes
        if averageSpeed > 0 && remainingBytes > 0 {
            self.state.estimatedTimeRemainingSeconds = Double(remainingBytes) / averageSpeed
        } else {
            self.state.estimatedTimeRemainingSeconds = nil
        }

        self.lastProgressUpdateTime = now
        self.lastBytesDownloaded = currentBytes
    }

    private func ensurePrimaryLLMSelected() async {
        // Wait for ModelManager to finish loading metadata before modifying state
        await ModelManager.shared.ensureInitialized()
        
        // Check if there's already a persisted primary LLM
        if let persistedLLM = await self.getPersistedPrimaryLLM() {
            // If persisted LLM is a legacy model, force migration to Qwen 3
            if persistedLLM.isLegacy {
                self.logger.info("Legacy model \(persistedLLM.displayName) detected, migrating to Qwen 3 4B")
                self.state.primaryLLM = .qwen3_4B
                await ModelManager.shared.setPrimaryLLM(.qwen3_4B)
                return
            }
            self.state.primaryLLM = persistedLLM
            // Sync to ModelManager to ensure downloads use the correct LLM
            await ModelManager.shared.setPrimaryLLM(persistedLLM)
            return
        }

        // No persisted primary - use Qwen 3 4B
        let recommendedLLM: ModelIdentifier = .qwen3_4B
        self.state.primaryLLM = recommendedLLM
        await ModelManager.shared.setPrimaryLLM(recommendedLLM)
    }

    private func getPersistedPrimaryLLM() async -> ModelIdentifier? {
        await Task.detached {
            let url = ModelPaths.metadataFile
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            guard let metadata = try? decoder.decode([PersistedModelMetadata].self, from: data) else { return nil }
            return metadata.first { $0.isPrimary && $0.identifier.category == .llm }?.identifier
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
