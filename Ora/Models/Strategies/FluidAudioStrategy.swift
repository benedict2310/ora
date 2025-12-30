//
//  FluidAudioStrategy.swift
//  Ora
//
//  Download strategy for Parakeet ASR models using FluidAudio SDK
//

import Foundation
import os

/// Strategy for downloading ASR models via ParakeetBootstrap (FluidAudio SDK)
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

            switch state {
            case .running(let progress, _, _, _):
                let modelProgress = ModelDownloadProgress(
                    identifier: model,
                    progress: progress
                )
                handler(modelProgress)

            case .verifying:
                // Verifying is ~95% complete
                let modelProgress = ModelDownloadProgress(
                    identifier: model,
                    progress: 0.95
                )
                handler(modelProgress)

            case .done:
                let modelProgress = ModelDownloadProgress(
                    identifier: model,
                    progress: 1.0
                )
                handler(modelProgress)

            case .idle, .failed:
                break
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
