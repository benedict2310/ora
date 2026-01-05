//
//  ModelManager.swift
//  Ora
//
//  Centralized AI model management: downloads, storage, lifecycle
//

import Foundation
import os

/// Centralized manager for all AI models
actor ModelManager {

    // MARK: - Singleton

    static let shared = ModelManager()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "ModelManager")
    private let downloader: ModelDownloader
    private var _state = ModelsState()
    private var downloadTasks: [ModelIdentifier: Task<Void, Error>] = [:]
    private var hasLoadedMetadata = false

    /// Current state
    var state: ModelsState {
        _state
    }

    // MARK: - Initialization

    private init() {
        self.downloader = DefaultModelDownloader.shared
        // Kick off async initialization
        Task {
            await self.performInitialLoad()
        }
    }

    /// Create with custom downloader (for testing)
    init(downloader: ModelDownloader) {
        self.downloader = downloader
        // Test instances don't need async initialization
    }
    
    private func performInitialLoad() async {
        await self.loadMetadataIfNeeded()
        await self.refreshStatuses()
    }

    /// Wait for initialization to complete (metadata loaded, statuses refreshed)
    /// Call this before setPrimaryLLM to ensure metadata is loaded first
    func ensureInitialized() async {
        await self.loadMetadataIfNeeded()
    }
    
    private func loadMetadataIfNeeded() async {
        guard !self.hasLoadedMetadata else { return }
        self.loadMetadata()
        self.hasLoadedMetadata = true
    }

    // MARK: - Public API

    /// Refresh status of all models
    func refreshStatuses() async {
        self.logger.debug("Refreshing model statuses...")

        for model in ModelIdentifier.allCases {
            let path = ModelPaths.path(for: model)
            if self.downloader.exists(model: model, at: path) {
                _state.statuses[model] = .ready
            } else {
                _state.statuses[model] = .notDownloaded
            }
        }

        await self.postStateChange()
    }

    /// Check if required models are available
    func requiredModelsAvailable() async -> Bool {
        await self.refreshStatuses()
        return _state.requiredModelsReady
    }

    /// Select which LLM to use as primary
    func setPrimaryLLM(_ model: ModelIdentifier) async {
        guard model.category == .llm else { return }
        _state.primaryLLM = model

        // Update metadata for all LLM models
        for llm in ModelIdentifier.allCases where llm.category == .llm {
            if var meta = _state.metadata[llm] {
                meta.isPrimary = (llm == model)
                _state.metadata[llm] = meta
            }
        }

        await self.saveMetadata()
        await self.postStateChange()
        self.logger.info("Primary LLM set to: \(model.displayName)")
    }

    /// Get recommended LLM based on system RAM
    func recommendedLLM() -> ModelIdentifier {
        // Qwen 3 4B is now the only recommended model
        return .qwen3_4B
    }

    /// Download all required models in parallel
    func downloadRequiredModels(
        progress: (@Sendable (OverallDownloadProgress) -> Void)? = nil
    ) async throws {
        let modelsToDownload: [ModelIdentifier] = [.parakeetTDT, _state.primaryLLM, .kokoro]

        self.logger.info("Starting download of \(modelsToDownload.count) models...")

        try ModelPaths.ensureDirectoriesExist()

        // Track individual progress
        let progressTracker = ProgressTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for model in modelsToDownload {
                group.addTask {
                    try await self.downloadModel(model) { modelProgress in
                        Task {
                            await progressTracker.update(model: model, progress: modelProgress)
                            let overall = await progressTracker.calculateOverall(models: modelsToDownload)
                            progress?(overall)
                        }
                    }
                }
            }

            try await group.waitForAll()
        }

        await self.refreshStatuses()
        self.logger.info("All required models downloaded successfully")
    }

    /// Download a single model (starts a tracked task for cancellation support)
    func downloadModel(
        _ model: ModelIdentifier,
        progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil
    ) async throws {
        // Cancel any existing download for this model
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil

        let path = ModelPaths.path(for: model)

        // Check if already downloaded
        if self.downloader.exists(model: model, at: path) {
            self.logger.debug("\(model.rawValue) already exists, skipping download")
            _state.statuses[model] = .ready
            await self.postStateChange()
            return
        }

        self.logger.info("Downloading \(model.displayName)...")
        _state.statuses[model] = .downloading(progress: 0)
        await self.postStateChange()

        // Create a task we can track for cancellation
        let downloadTask = Task {
            try await self.performDownload(model: model, to: path, progress: progress)
        }
        downloadTasks[model] = downloadTask

        do {
            try await downloadTask.value
            downloadTasks[model] = nil
        } catch {
            downloadTasks[model] = nil
            throw error
        }
    }

    /// Internal download implementation
    private func performDownload(
        model: ModelIdentifier,
        to path: URL,
        progress: (@Sendable (ModelDownloadProgress) -> Void)?
    ) async throws {
        do {
            // Check for cancellation before starting
            try Task.checkCancellation()

            // Create directory
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

            // Download with guarded progress updates
            try await self.downloader.download(model: model, to: path) { [weak self] modelProgress in
                guard let self = self else { return }
                Task {
                    await self.updateDownloadProgressIfDownloading(model: model, progress: modelProgress.progress)
                }
                progress?(modelProgress)
            }

            // Check for cancellation before verification
            try Task.checkCancellation()

            // Verify
            _state.statuses[model] = .verifying
            await self.postStateChange()

            let verified = await self.downloader.verify(model: model, at: path)
            if verified {
                _state.statuses[model] = .ready
                _state.metadata[model] = ModelMetadata(
                    identifier: model,
                    sizeBytes: ModelPaths.directorySize(at: path),
                    isPrimary: model == _state.primaryLLM
                )
                await self.saveMetadata()
                self.logger.info("\(model.displayName) downloaded and verified")
            } else {
                _state.statuses[model] = .corrupted
                self.logger.error("\(model.displayName) verification failed")
                throw ModelError.verificationFailed(model)
            }

            await self.postStateChange()

        } catch is CancellationError {
            // Clean up partial download on cancellation
            try? ModelPaths.removeModel(model)
            _state.statuses[model] = .notDownloaded
            await self.postStateChange()
            self.logger.info("Download cancelled for \(model.displayName)")
            throw ModelError.downloadCancelled(model)
        } catch {
            _state.statuses[model] = .failed(error.localizedDescription)
            await self.postStateChange()
            self.logger.error("Failed to download \(model.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Cancel a download in progress
    func cancelDownload(_ model: ModelIdentifier) async {
        guard let task = downloadTasks[model] else {
            self.logger.debug("No active download to cancel for \(model.displayName)")
            return
        }

        task.cancel()
        downloadTasks[model] = nil

        // Wait briefly for the task to handle cancellation
        try? await Task.sleep(for: .milliseconds(50))

        // Ensure state is updated (in case task cleanup didn't run)
        if _state.statuses[model]?.isDownloading == true {
            _state.statuses[model] = .notDownloaded
            await self.postStateChange()
        }

        self.logger.info("Cancelled download for \(model.displayName)")
    }

    /// Delete a downloaded model
    func deleteModel(_ model: ModelIdentifier) async throws {
        try ModelPaths.removeModel(model)

        _state.statuses[model] = .notDownloaded
        _state.metadata[model] = nil
        await self.saveMetadata()
        await self.postStateChange()

        self.logger.info("Deleted \(model.displayName)")
    }

    /// Get path for a ready model
    func pathForModel(_ model: ModelIdentifier) -> URL? {
        guard _state.statuses[model]?.isReady ?? false else { return nil }
        return ModelPaths.path(for: model)
    }

    // MARK: - Private: Progress Tracking

    /// Update download progress only if model is still in downloading state
    /// This prevents late-arriving progress updates from regressing state
    private func updateDownloadProgressIfDownloading(model: ModelIdentifier, progress: Double) async {
        // Only update if still downloading - prevents race where progress arrives
        // after verification/ready state has been set
        guard _state.statuses[model]?.isDownloading == true else {
            return
        }
        _state.statuses[model] = .downloading(progress: progress)
        await self.postDownloadProgress(model: model, progress: progress)
    }

    // MARK: - Private: Metadata Persistence

    private func loadMetadata() {
        let path = ModelPaths.metadataFile
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode([ModelMetadata].self, from: data)

            for meta in metadata {
                _state.metadata[meta.identifier] = meta
                if meta.isPrimary && meta.identifier.category == .llm {
                    _state.primaryLLM = meta.identifier
                }
            }
            self.logger.debug("Loaded metadata for \(metadata.count) models")
        } catch {
            self.logger.warning("Failed to load model metadata: \(error.localizedDescription)")
        }
    }

    private func saveMetadata() async {
        let path = ModelPaths.metadataFile
        let metadata = Array(_state.metadata.values)

        do {
            try ModelPaths.ensureDirectoriesExist()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: path)
            self.logger.debug("Saved metadata for \(metadata.count) models")
        } catch {
            self.logger.warning("Failed to save model metadata: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Notifications

    private func postStateChange() async {
        let currentState = _state
        await MainActor.run {
            NotificationCenter.default.post(
                name: .modelStateDidChange,
                object: currentState
            )
        }
    }

    private func postDownloadProgress(model: ModelIdentifier, progress: Double) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .modelDownloadProgress,
                object: nil,
                userInfo: ["model": model, "progress": progress]
            )
        }
    }
}

// MARK: - Progress Tracker

/// Actor to safely track progress across concurrent downloads
private actor ProgressTracker {
    private var progressMap: [ModelIdentifier: ModelDownloadProgress] = [:]

    func update(model: ModelIdentifier, progress: ModelDownloadProgress) {
        progressMap[model] = progress
    }

    func calculateOverall(models: [ModelIdentifier]) -> OverallDownloadProgress {
        OverallDownloadProgress.calculate(from: progressMap, models: models)
    }
}
