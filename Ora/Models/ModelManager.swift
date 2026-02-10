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

    /// BUG.04 FIX: Track models currently being downloaded to prevent concurrent downloads
    /// of the same model, which can cause race conditions and file corruption.
    private var activeDownloads: Set<ModelIdentifier> = []
    
    // MARK: - Speed Tracking
    
    private var downloadSpeedSamples: [Double] = []
    private var lastProgressUpdateTime: Date?
    private var lastTotalBytesDownloaded: Int64 = 0
    private let maxSpeedSamples = 5

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
    /// Call this before accessing state or setPrimaryLLM to ensure full initialization
    func ensureInitialized() async {
        await self.loadMetadataIfNeeded()
        await self.refreshStatuses()
    }
    
    private func loadMetadataIfNeeded() async {
        guard !self.hasLoadedMetadata else { return }
        self.loadMetadata()
        self.hasLoadedMetadata = true
    }

    // MARK: - Public API

    /// Refresh status of all models
    func refreshStatuses() async {
        self.logger.info("Refreshing model statuses...")

        var readyCount = 0
        var missingCount = 0
        var missingModels: [String] = []

        for model in ModelIdentifier.allCases {
            let path = ModelPaths.path(for: model)
            if self.downloader.exists(model: model, at: path) {
                _state.statuses[model] = .ready
                readyCount += 1
            } else {
                _state.statuses[model] = .notDownloaded
                missingCount += 1
                missingModels.append(model.displayName)
            }
        }

        self.logger.info("Status refresh complete: \(readyCount) ready, \(missingCount) not downloaded")
        if !missingModels.isEmpty {
            self.logger.warning("Missing models: \(missingModels.joined(separator: ", "), privacy: .public)")
        }
        
        // Log the required models specifically
        let asrReady = _state.statuses[.parakeetTDT]?.isReady ?? false
        let ttsReady = _state.statuses[.kokoro]?.isReady ?? false
        let primaryLLM = _state.primaryLLM
        let llmReady = _state.statuses[primaryLLM]?.isReady ?? false
        self.logger.info("Required models: ASR=\(asrReady), TTS=\(ttsReady), LLM(\(primaryLLM.displayName, privacy: .public))=\(llmReady)")
        await self.postStateChange()
    }

    /// Check if required models are available
    /// Includes multiple retries with increasing delays for transient filesystem failures (e.g., after app re-signing)
    func requiredModelsAvailable() async -> Bool {
        // First attempt
        await self.refreshStatuses()

        if _state.requiredModelsReady {
            self.logger.info("Required models available on first check")
            return true
        }

        // Retry with increasing delays to handle transient filesystem access issues
        // This handles delays after app re-signing when macOS may still be verifying code signatures
        let retryDelays: [Duration] = [.milliseconds(500), .milliseconds(1000)]
        
        for (index, delay) in retryDelays.enumerated() {
            self.logger.warning("Models not ready (attempt \(index + 1)), retrying after \(delay)...")
            try? await Task.sleep(for: delay)
            await self.refreshStatuses()
            
            if _state.requiredModelsReady {
                self.logger.info("Models available after retry \(index + 1)")
                return true
            }
        }

        self.logger.error("Models still not ready after \(retryDelays.count) retries - will prompt for re-download")
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
        
        // Initialize download state
        _state.isDownloading = true
        resetSpeedTracking()
        
        // Initialize total bytes to download (for models not yet ready)
        var totalBytesToDownload: Int64 = 0
        for model in modelsToDownload {
            let path = ModelPaths.path(for: model)
            if !self.downloader.exists(model: model, at: path) {
                totalBytesToDownload += model.estimatedSizeBytes
                _state.downloadProgress[model] = ModelDownloadProgress(
                    identifier: model,
                    bytesDownloaded: 0,
                    totalBytes: model.estimatedSizeBytes
                )
            }
        }
        
        await postStateChange()
        
        defer {
            // Clean up download state when done
            Task {
                await self.cleanupDownloadState()
            }
        }

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

        // Save metadata once after all downloads complete to ensure atomic persistence
        // This guards against any race conditions from individual saves during parallel downloads
        await self.saveMetadata()

        await self.refreshStatuses()
        self.logger.info("All required models downloaded successfully")
    }
    
    /// Clean up download state after completion or cancellation
    private func cleanupDownloadState() async {
        _state.isDownloading = false
        _state.downloadProgress = [:]
        _state.overallDownloadSpeed = 0
        _state.estimatedTimeRemainingSeconds = nil
        await postStateChange()
    }
    
    /// Reset speed tracking state
    private func resetSpeedTracking() {
        downloadSpeedSamples = []
        lastProgressUpdateTime = nil
        lastTotalBytesDownloaded = 0
    }
    
    /// Update download speed calculation
    private func updateDownloadSpeed() {
        let now = Date()
        let currentTotal = _state.totalBytesDownloaded
        
        guard let lastTime = lastProgressUpdateTime else {
            lastProgressUpdateTime = now
            lastTotalBytesDownloaded = currentTotal
            return
        }
        
        let timeDelta = now.timeIntervalSince(lastTime)
        guard timeDelta > 0.1 else { return }
        
        let bytesDelta = currentTotal - lastTotalBytesDownloaded
        guard bytesDelta > 0 else { return }
        
        let speed = Double(bytesDelta) / timeDelta
        downloadSpeedSamples.append(speed)
        if downloadSpeedSamples.count > maxSpeedSamples {
            downloadSpeedSamples.removeFirst()
        }
        
        let averageSpeed = downloadSpeedSamples.reduce(0, +) / Double(downloadSpeedSamples.count)
        _state.overallDownloadSpeed = averageSpeed
        
        let remainingBytes = _state.totalBytesToDownload - currentTotal
        if averageSpeed > 0 && remainingBytes > 0 {
            _state.estimatedTimeRemainingSeconds = Double(remainingBytes) / averageSpeed
        } else {
            _state.estimatedTimeRemainingSeconds = nil
        }
        
        lastProgressUpdateTime = now
        lastTotalBytesDownloaded = currentTotal
    }

    /// Download a single model (starts a tracked task for cancellation support)
    func downloadModel(
        _ model: ModelIdentifier,
        progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil
    ) async throws {
        // BUG.04 FIX: Check if this model is already being downloaded
        // This prevents race conditions when multiple callers try to download the same model
        guard !self.activeDownloads.contains(model) else {
            self.logger.info("\(model.displayName) download already in progress, skipping duplicate request")
            return
        }

        // Cancel any existing download task for this model (belt and suspenders)
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil

        let path = ModelPaths.path(for: model)

        // Check if already downloaded
        if self.downloader.exists(model: model, at: path) {
            self.logger.debug("\(model.rawValue) already exists, skipping download")
            _state.statuses[model] = .ready

            // Notify listener that we are effectively 100% done
            progress?(ModelDownloadProgress(identifier: model, progress: 1.0))

            await self.postStateChange()
            return
        }

        // Mark this model as being downloaded (prevents concurrent downloads)
        self.activeDownloads.insert(model)
        defer { self.activeDownloads.remove(model) }

        // DIAGNOSTIC: Log download trigger to file (BUG.04 investigation)
        self.logDiagnostic("DOWNLOAD TRIGGERED for \(model.displayName) - model did not exist at \(path.path)")
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

            // FluidAudio manages Parakeet leaf directory creation under its parent.
            let directoryToCreate = model == .parakeetTDT ? path.deletingLastPathComponent() : path
            try FileManager.default.createDirectory(at: directoryToCreate, withIntermediateDirectories: true)

            // Download with guarded progress updates
            try await self.downloader.download(model: model, to: path) { [weak self] modelProgress in
                guard let self = self else { return }
                Task {
                    await self.updateDownloadProgressIfDownloading(model: model, progress: modelProgress.progress, modelProgress: modelProgress)
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
            // BUG.04 FIX: DO NOT delete the entire model directory on cancellation!
            // The directory may contain valid files from a previous successful download.
            // The atomic download pattern in HuggingFaceDownloader uses .tmp files,
            // so we only need to clean up orphaned .tmp files, not the whole directory.
            self.cleanupTempFiles(in: path)
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
    private func updateDownloadProgressIfDownloading(model: ModelIdentifier, progress: Double, modelProgress: ModelDownloadProgress? = nil) async {
        // Only update if still downloading - prevents race where progress arrives
        // after verification/ready state has been set
        guard _state.statuses[model]?.isDownloading == true else {
            return
        }
        _state.statuses[model] = .downloading(progress: progress)
        
        // Update download progress dictionary for unified tracking
        if let modelProgress = modelProgress {
            _state.downloadProgress[model] = modelProgress
        } else {
            // Create from progress percentage if no detailed progress available
            _state.downloadProgress[model] = ModelDownloadProgress(
                identifier: model,
                progress: progress
            )
        }
        
        // Update speed calculation
        updateDownloadSpeed()
        
        await self.postStateChange()
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

    // MARK: - Cleanup Helpers

    /// Clean up only temporary (.tmp) files created during download, NOT valid model files
    /// BUG.04 FIX: This is the safe cleanup method that doesn't destroy existing valid files
    private nonisolated func cleanupTempFiles(in directory: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }

        // Get all files in the directory (non-recursive for safety)
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            // Only clean up .tmp files (download in progress files)
            if fileURL.pathExtension == "tmp" {
                self.logDiagnostic("CLEANUP: Removing temp file \(fileURL.lastPathComponent)")
                try? fm.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - Diagnostic Logging

    /// Log diagnostic messages to file (os_log info level doesn't persist)
    /// Writes to ~/Library/Application Support/Ora/model-diagnostic.log
    private nonisolated func logDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let oraDir = appSupport.appendingPathComponent("Ora")
        let logFile = oraDir.appendingPathComponent("model-diagnostic.log")

        try? fm.createDirectory(at: oraDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            }
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
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
