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
    
    /// Models state synced from ModelManager (single source of truth)
    @Published private(set) var modelsState = ModelsState()

    // MARK: - Properties

    private let logger = Logger.ora(category: "SetupCoordinator")
    private var setupWindow: NSWindow?
    private var downloadTask: Task<Void, Never>?
    
    /// Notification observer for ModelManager state changes
    /// Using nonisolated(unsafe) to allow access from deinit
    nonisolated(unsafe) private var modelStateObserver: NSObjectProtocol?

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
        self.setupModelStateObserver()
    }
    
    deinit {
        if let observer = modelStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Model State Observer
    
    private func setupModelStateObserver() {
        modelStateObserver = NotificationCenter.default.addObserver(
            forName: .modelStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let newState = notification.object as? ModelsState else { return }
            // This is already on main queue, but we need MainActor isolation
            MainActor.assumeIsolated {
                self.handleModelStateChange(newState)
            }
        }
    }
    
    private func handleModelStateChange(_ newState: ModelsState) {
        modelsState = newState
        
        // Update SetupState.downloadProgress from ModelsState for backward compatibility
        state.downloadProgress = newState.overallProgress
        
        // Check if all required models are ready and we're on the download step
        if state.currentStep == .download && newState.requiredModelsReady && !state.downloadWasCancelled {
            state.currentStep = .ready
        }
    }

    // MARK: - Public API

    /// Check if setup is needed and show if required
    /// - Returns: `true` if setup is needed and was shown, `false` if setup was already complete and models are available
    func checkAndShowSetupIfNeeded() async -> Bool {
        // Ensure ModelManager metadata is loaded before checking status
        await ModelManager.shared.ensureInitialized()
        
        // Sync initial state from ModelManager
        modelsState = await ModelManager.shared.state
        
        let isComplete = UserDefaults.standard.oraSetupComplete

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
        UserDefaults.standard.oraSetupComplete
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

    /// Bring the setup window to the front if it's already showing
    func bringSetupToFront() {
        guard self.isShowingSetup else { return }
        if self.setupWindow == nil {
            self.showSetup()
            return
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
        self.state.downloadError = nil
        self.state.downloadProgress = 0

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

        // Reset download state (only setup-specific state)
        self.state.downloadProgress = 0
        self.state.downloadError = nil
        self.state.downloadWasCancelled = false

        // Start the download in a tracked task for cancellation support
        self.downloadTask = Task { @MainActor in
            do {
                // Let ModelManager handle all progress tracking via notifications
                try await ModelManager.shared.downloadRequiredModels { _ in
                    // Progress is now handled via notification observer in handleModelStateChange
                }

                self.state.downloadProgress = 1.0
                self.state.downloadingModel = nil

                self.logger.info("All downloads complete")

                // Auto-advance to ready (also handled by notification observer, but belt-and-suspenders)
                if self.state.currentStep == .download {
                    self.state.currentStep = .ready
                }

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
        // Wait for ModelManager to finish loading metadata before modifying state
        await ModelManager.shared.ensureInitialized()

        let persistedLLM = await self.getPersistedPrimaryLLM()
        let totalRAMBytes = ProcessInfo.processInfo.physicalMemory
        let isRepairFlow = UserDefaults.standard.oraSetupComplete
        let resolvedLLM = Self.resolvePrimaryLLM(
            persistedLLM: persistedLLM,
            isRepairFlow: isRepairFlow,
            totalRAMBytes: totalRAMBytes
        )
        self.state.primaryLLM = resolvedLLM
        await ModelManager.shared.setPrimaryLLM(resolvedLLM, totalRAMBytes: totalRAMBytes)
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
        UserDefaults.standard.oraSetupComplete = true
        self.isShowingSetup = false
        self.setupWindow?.close()
        self.setupWindow = nil
        self.logger.info("Setup completed successfully")

        // Notify app that setup is done
        NotificationCenter.default.post(name: .setupDidComplete, object: nil)
    }
}

extension SetupCoordinator {
    static func resolvePrimaryLLM(
        persistedLLM: ModelIdentifier?,
        isRepairFlow: Bool,
        totalRAMBytes: UInt64
    ) -> ModelIdentifier {
        guard let persistedLLM else {
            return .qwen3_4B
        }

        if persistedLLM.isLegacy {
            return .qwen3_4B
        }

        if persistedLLM == .qwen35_4B_Vision && !isRepairFlow {
            return .qwen3_4B
        }

        if !persistedLLM.isSupported(on: totalRAMBytes) {
            return .qwen3_4B
        }

        return persistedLLM
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
