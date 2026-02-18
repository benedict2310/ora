//
//  FluidAudioStrategy.swift
//  Ora
//
//  Download strategy for Parakeet ASR models using FluidAudio SDK
//

import Foundation
import FluidAudio
import os

/// Strategy for downloading ASR models via FluidAudio SDK
struct FluidAudioStrategy: ModelDownloadStrategy, Sendable {

    private let logger = Logger.ora(category: "FluidAudioStrategy")
    static let maxEstimatedProgressBeforeVerification: Double = 0.90

    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        guard model.category == .asr else {
            throw ModelError.downloadFailed(model, "FluidAudioStrategy only supports ASR models")
        }

        switch model {
        case .parakeetTDT:
            try await downloadTDTModel(to: directory, progress: progress)
        default:
            throw ModelError.downloadFailed(model, "Unknown ASR model: \(model.rawValue)")
        }
    }

    // MARK: - TDT Model Download (Batch Mode)

    private func downloadTDTModel(
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let model = ModelIdentifier.parakeetTDT

        // Note: FluidAudio SDK manages its own download directory (ParakeetModelDownloader.repoDirectory)
        // which is set to ModelPaths.path(for: .parakeetTDT). We verify the paths match to catch
        // any configuration drift.
        let expectedPath = ParakeetModelDownloader.repoDirectory
        if directory != expectedPath {
            self.logger.warning("Directory mismatch: expected \(expectedPath.path), got \(directory.path). Using expected path.")
        }

        self.logger.info("Starting FluidAudio download for \(model.displayName)")

        let progressReporter = FluidAudioProgressReporter(
            model: model,
            logger: self.logger,
            progressHandler: progress
        )
        await progressReporter.emit(
            ModelDownloadProgress(identifier: model, progress: 0.0),
            source: .initial
        )

        // FluidAudio SDK handles download internally. We combine SDK notifications with
        // a file-size-based estimator so onboarding does not appear stuck at 0%.
        let progressObserver = FluidAudioProgressObserver(
            model: model,
            progressReporter: progressReporter
        )
        let progressEstimator = FluidAudioDirectoryProgressEstimator(
            model: model,
            directory: expectedPath,
            progressReporter: progressReporter
        )

        // Start observing before download
        await progressObserver.startObserving()
        await progressEstimator.start()

        defer {
            Task {
                await progressObserver.stopObserving()
                await progressEstimator.stop()
            }
        }

        do {
            // ParakeetBootstrap.downloadModels() handles everything:
            // - HuggingFace download
            // - CoreML compilation
            // - Model initialization
            try await ParakeetBootstrap.shared.downloadModels()

            // Emit completion
            await progressReporter.emit(
                ModelDownloadProgress(identifier: model, progress: 1.0),
                source: .completion
            )
            self.logger.info("FluidAudio download complete for \(model.displayName)")

        } catch {
            self.logger.error("FluidAudio download failed: \(error.localizedDescription)")
            throw ModelError.downloadFailed(model, error.localizedDescription)
        }
    }

    static func progress(
        for state: ParakeetModelDownloader.State,
        model: ModelIdentifier
    ) -> ModelDownloadProgress? {
        switch state {
        case .running(let progress, _, _, let currentFile):
            return ModelDownloadProgress(identifier: model, progress: progress, currentFile: currentFile)
        case .verifying:
            return ModelDownloadProgress(identifier: model, progress: 0.95)
        case .done:
            return ModelDownloadProgress(identifier: model, progress: 1.0)
        case .idle, .failed:
            return nil
        }
    }

    static func estimatedProgressFromDirectorySize(_ sizeBytes: Int64, model: ModelIdentifier) -> Double {
        guard sizeBytes > 0 else { return 0.0 }

        let estimate = Double(sizeBytes) / Double(max(model.estimatedSizeBytes, 1))
        return min(max(estimate, 0.0), Self.maxEstimatedProgressBeforeVerification)
    }
}

// MARK: - Progress Observer

/// Observes ParakeetBootstrap notifications to forward progress updates
private actor FluidAudioProgressObserver {
    private let model: ModelIdentifier
    private let progressReporter: FluidAudioProgressReporter
    private var observer: NSObjectProtocol?

    init(model: ModelIdentifier, progressReporter: FluidAudioProgressReporter) {
        self.model = model
        self.progressReporter = progressReporter
    }

    func startObserving() {
        let model = self.model
        let progressReporter = self.progressReporter

        self.observer = NotificationCenter.default.addObserver(
            forName: .parakeetDownloadStateDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard let state = notification.object as? ParakeetModelDownloader.State else { return }

            if let modelProgress = FluidAudioStrategy.progress(for: state, model: model) {
                Task {
                    await progressReporter.emit(modelProgress, source: .notification)
                }
            }
        }
    }

    func stopObserving() {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

// MARK: - Directory Progress Estimator

private actor FluidAudioDirectoryProgressEstimator {
    private let model: ModelIdentifier
    private let directory: URL
    private let progressReporter: FluidAudioProgressReporter
    private var task: Task<Void, Never>?

    init(
        model: ModelIdentifier,
        directory: URL,
        progressReporter: FluidAudioProgressReporter
    ) {
        self.model = model
        self.directory = directory
        self.progressReporter = progressReporter
    }

    func start() {
        guard self.task == nil else { return }

        let directory = self.directory
        let model = self.model
        let progressReporter = self.progressReporter

        self.task = Task {
            while !Task.isCancelled {
                let size = ModelPaths.directorySize(at: directory)
                let estimatedProgress = FluidAudioStrategy.estimatedProgressFromDirectorySize(size, model: model)

                if estimatedProgress > 0 {
                    await progressReporter.emit(
                        ModelDownloadProgress(
                            identifier: model,
                            progress: estimatedProgress,
                            currentFile: "Parakeet model assets"
                        ),
                        source: .directoryEstimate
                    )
                }

                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func stop() {
        self.task?.cancel()
        self.task = nil
    }
}

// MARK: - Progress Reporter

private actor FluidAudioProgressReporter {
    enum Source {
        case initial
        case notification
        case directoryEstimate
        case completion
    }

    private let model: ModelIdentifier
    private let logger: Logger
    private let progressHandler: @Sendable (ModelDownloadProgress) -> Void

    private var lastProgress: Double = 0
    private var directoryEstimateFallbackLogged = false
    private var notificationProgressSeen = false

    init(
        model: ModelIdentifier,
        logger: Logger,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) {
        self.model = model
        self.logger = logger
        self.progressHandler = progressHandler
    }

    func emit(_ progress: ModelDownloadProgress, source: Source) {
        let clampedProgress = min(max(progress.progress, 0), 1)

        if source == .notification && clampedProgress > 0 {
            self.notificationProgressSeen = true
        }

        guard clampedProgress > self.lastProgress || (source == .completion && clampedProgress == 1.0) else {
            return
        }

        if source == .directoryEstimate && !self.notificationProgressSeen && !self.directoryEstimateFallbackLogged {
            self.directoryEstimateFallbackLogged = true
            self.logger.info("FLUIDAUDIO_PROGRESS_FALLBACK_DIRECTORY_ESTIMATE_ACTIVE")
        }

        self.lastProgress = clampedProgress
        self.progressHandler(
            ModelDownloadProgress(
                identifier: self.model,
                progress: clampedProgress,
                currentFile: progress.currentFile
            )
        )
    }
}
