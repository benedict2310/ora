//
//  ParakeetBootstrap.swift
//  Ora
//
//  Thread-safe singleton for Parakeet model lifecycle management
//

import Foundation
import CoreML
import FluidAudio
import os

// MARK: - FluidAudio Sendable Conformance

extension AsrManager: @unchecked Sendable {}

// MARK: - Bootstrap

final class ParakeetBootstrap: @unchecked Sendable {

    // MARK: - Types

    enum BootstrapError: LocalizedError, Sendable, Equatable {
        case modelsNotAvailable
        case loadFailed(String)
        case bootstrapDeallocated

        var errorDescription: String? {
            switch self {
            case .modelsNotAvailable:
                return "Parakeet models are not downloaded. Please download models first."
            case .loadFailed(let reason):
                return "Failed to load Parakeet models: \(reason)"
            case .bootstrapDeallocated:
                return "Bootstrap was deallocated during operation."
            }
        }
    }

    enum EngineState: Sendable, Equatable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    // MARK: - Singleton

    static let shared = ParakeetBootstrap()

    // MARK: - State Container

    private struct State: @unchecked Sendable {
        var engineState: EngineState = .idle
        var manager: AsrManager?
        var loadTask: Task<AsrManager, Error>?
    }

    // MARK: - Properties

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let downloader = ParakeetModelDownloader()
    private let logger = Logger(subsystem: "com.ora.asr", category: "ParakeetBootstrap")

    // MARK: - Initialization

    private init() {
        // Forward download state changes to notifications
        downloader.onState = { [weak self] state in
            self?.handleDownloadState(state)
        }
    }

    /// Create instance for testing (not singleton)
    init(forTesting: Bool) {
        downloader.onState = { [weak self] state in
            self?.handleDownloadState(state)
        }
    }

    // MARK: - Public API

    /// Current engine state
    func currentState() -> EngineState {
        stateLock.withLock { $0.engineState }
    }

    /// Current AsrManager instance (if ready)
    func currentManager() -> AsrManager? {
        stateLock.withLock { $0.manager }
    }

    /// Check if models are downloaded
    func modelsAvailable() -> Bool {
        downloader.modelsAvailable()
    }

    /// Ensure engine is ready, loading if necessary
    /// - Returns: Initialized AsrManager
    /// - Throws: BootstrapError if models unavailable or loading fails
    func ensureReady() async throws -> AsrManager {
        // Fast path: already ready
        if let manager = currentManager() {
            return manager
        }

        // Check for existing load task
        if let existingTask = stateLock.withLock({ $0.loadTask }) {
            return try await existingTask.value
        }

        // Create new load task
        let task = Task { [weak self] () throws -> AsrManager in
            guard let self else {
                throw BootstrapError.bootstrapDeallocated
            }

            // Verify models exist
            try await self.ensureModelsAvailable()

            // Load and initialize
            let manager = try await self.loadManager()
            return manager
        }

        // Store task for deduplication
        stateLock.withLock { state in
            state.loadTask = task
        }

        do {
            let manager = try await task.value
            stateLock.withLock { state in
                state.manager = manager
                state.loadTask = nil
            }
            setEngineState(.ready)
            logger.info("Parakeet engine ready")
            return manager
        } catch {
            stateLock.withLock { state in
                state.loadTask = nil
            }

            // Distinguish between "not downloaded" and actual failures
            if let bootstrapError = error as? BootstrapError,
               bootstrapError == .modelsNotAvailable {
                setEngineState(.idle)
            } else {
                setEngineState(.failed(error.localizedDescription))
            }

            logger.error("Parakeet bootstrap failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Reset the decoder state for a new session
    func reset() async {
        guard let manager = currentManager() else { return }
        do {
            try await manager.resetDecoderState()
            logger.debug("Decoder state reset")
        } catch {
            logger.warning("Failed to reset decoder state: \(error.localizedDescription)")
        }
    }

    /// Download models using FluidAudio SDK
    /// - Returns: URL to downloaded model directory
    @discardableResult
    func downloadModels() async throws -> URL {
        setEngineState(.downloading)
        downloader.notifyState(.running(progress: 0, fileIndex: 0, fileCount: 1, currentFile: "Parakeet TDT"))

        let modelsPath = ParakeetModelDownloader.repoDirectory

        do {
            // Create directory if needed
            try FileManager.default.createDirectory(at: modelsPath, withIntermediateDirectories: true)

            // Configure for Neural Engine with CPU fallback
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine

            logger.info("Downloading Parakeet models to: \(modelsPath.path)")

            // FluidAudio handles HuggingFace download, caching, and CoreML compilation
            let models = try await AsrModels.downloadAndLoad(
                to: modelsPath,
                configuration: config,
                version: .v3
            )

            // Verify download
            downloader.notifyState(.verifying)
            try downloader.verifyModelsExist()

            // Initialize manager to verify models work
            let manager = AsrManager()
            try await manager.initialize(models: models)

            // Store manager
            stateLock.withLock { state in
                state.manager = manager
            }

            downloader.notifyState(.done(modelsPath))
            setEngineState(.ready)
            logger.info("Models downloaded to: \(modelsPath.path)")
            return modelsPath

        } catch {
            downloader.notifyState(.failed(error))
            setEngineState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Invalidate current manager (for testing or reconfiguration)
    func invalidate() {
        stateLock.withLock { state in
            state.manager = nil
            state.loadTask?.cancel()
            state.loadTask = nil
            state.engineState = .idle
        }
        setEngineState(.idle)
    }

    // MARK: - Private Helpers

    private func ensureModelsAvailable() async throws {
        guard downloader.modelsAvailable() else {
            throw BootstrapError.modelsNotAvailable
        }
    }

    private func loadManager() async throws -> AsrManager {
        setEngineState(.loading)

        // Configure for Neural Engine with CPU fallback
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        // Load models from disk
        let modelsPath = ParakeetModelDownloader.repoDirectory
        logger.debug("Loading models from: \(modelsPath.path)")

        do {
            let models = try await AsrModels.load(
                from: modelsPath,
                configuration: config,
                version: .v3
            )

            // Initialize manager
            let manager = AsrManager()
            try await manager.initialize(models: models)

            return manager
        } catch {
            throw BootstrapError.loadFailed(error.localizedDescription)
        }
    }

    private func handleDownloadState(_ state: ParakeetModelDownloader.State) {
        NotificationCenter.default.post(
            name: .parakeetDownloadStateDidChange,
            object: state
        )
    }

    private func setEngineState(_ state: EngineState) {
        stateLock.withLock { $0.engineState = state }
        NotificationCenter.default.post(
            name: .parakeetEngineStateDidChange,
            object: state
        )
    }
}
