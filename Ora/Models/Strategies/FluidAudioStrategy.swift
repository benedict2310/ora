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

    private let logger = Logger(subsystem: "com.ora.app", category: "FluidAudioStrategy")

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
        case .parakeetEOU160:
            try await downloadStreamingModel(chunkSize: .ms160, to: directory, progress: progress, model: model)
        case .parakeetEOU320:
            try await downloadStreamingModel(chunkSize: .ms320, to: directory, progress: progress, model: model)
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

        // Emit initial progress
        progress(ModelDownloadProgress(identifier: model, progress: 0.0))

        // FluidAudio SDK handles download internally via ParakeetBootstrap
        // We observe download state via notifications for progress updates
        let progressObserver = FluidAudioProgressObserver(
            model: model,
            progressHandler: progress
        )

        // Start observing before download
        await progressObserver.startObserving()

        defer {
            Task {
                await progressObserver.stopObserving()
            }
        }

        do {
            // ParakeetBootstrap.downloadModels() handles everything:
            // - HuggingFace download
            // - CoreML compilation
            // - Model initialization
            try await ParakeetBootstrap.shared.downloadModels()

            // Emit completion
            progress(ModelDownloadProgress(identifier: model, progress: 1.0))
            self.logger.info("FluidAudio download complete for \(model.displayName)")

        } catch {
            self.logger.error("FluidAudio download failed: \(error.localizedDescription)")
            throw ModelError.downloadFailed(model, error.localizedDescription)
        }
    }

    // MARK: - Streaming EOU Model Download

    private func downloadStreamingModel(
        chunkSize: StreamingChunkSize,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void,
        model: ModelIdentifier
    ) async throws {
        self.logger.info("Starting streaming EOU model download for \(model.displayName)")

        // Emit initial progress
        progress(ModelDownloadProgress(identifier: model, progress: 0.0))

        // Get the repo for this chunk size
        let repo: Repo
        switch chunkSize {
        case .ms160:
            repo = .parakeetEou160
        case .ms320:
            repo = .parakeetEou320
        case .ms1600:
            throw ModelError.downloadFailed(model, "1600ms chunk size not supported")
        }

        do {
            // Create target directory if needed
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // Download each required file using FluidAudio's AssetDownloader
            let requiredFiles = ModelNames.ParakeetEOU.requiredModels
            let totalFiles = requiredFiles.count
            var downloadedCount = 0

            for fileName in requiredFiles {
                // Build remote URL with subPath for the chunk size variant
                let remotePath: String
                if let subPath = repo.subPath {
                    remotePath = "\(subPath)/\(fileName)"
                } else {
                    remotePath = fileName
                }

                let remoteURL = try ModelRegistry.resolveModel(repo.remotePath, remotePath)
                let localURL = directory.appendingPathComponent(fileName)

                let descriptor = AssetDownloader.Descriptor(
                    description: fileName,
                    remoteURL: remoteURL,
                    destinationURL: localURL
                )

                _ = try await AssetDownloader.ensure(descriptor)

                downloadedCount += 1
                let progressValue = Double(downloadedCount) / Double(totalFiles)
                progress(ModelDownloadProgress(identifier: model, progress: progressValue))
            }

            // Emit completion
            progress(ModelDownloadProgress(identifier: model, progress: 1.0))
            self.logger.info("Streaming EOU model download complete for \(model.displayName)")

        } catch {
            self.logger.error("Streaming EOU model download failed: \(error.localizedDescription)")
            throw ModelError.downloadFailed(model, error.localizedDescription)
        }
    }

    static func progress(
        for state: ParakeetModelDownloader.State,
        model: ModelIdentifier
    ) -> ModelDownloadProgress? {
        switch state {
        case .running(let progress, _, _, _):
            return ModelDownloadProgress(identifier: model, progress: progress)
        case .verifying:
            return ModelDownloadProgress(identifier: model, progress: 0.95)
        case .done:
            return ModelDownloadProgress(identifier: model, progress: 1.0)
        case .idle, .failed:
            return nil
        }
    }
}

// MARK: - Progress Observer

/// Observes ParakeetBootstrap notifications to forward progress updates
private actor FluidAudioProgressObserver {
    private let model: ModelIdentifier
    private let progressHandler: @Sendable (ModelDownloadProgress) -> Void
    private var observer: NSObjectProtocol?

    init(model: ModelIdentifier, progressHandler: @escaping @Sendable (ModelDownloadProgress) -> Void) {
        self.model = model
        self.progressHandler = progressHandler
    }

    func startObserving() {
        let handler = self.progressHandler
        let model = self.model

        self.observer = NotificationCenter.default.addObserver(
            forName: .parakeetDownloadStateDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard let state = notification.object as? ParakeetModelDownloader.State else { return }

            if let modelProgress = FluidAudioStrategy.progress(for: state, model: model) {
                handler(modelProgress)
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
