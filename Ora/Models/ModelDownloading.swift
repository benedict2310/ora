//
//  ModelDownloading.swift
//  Ora
//
//  Protocol for model downloaders (enables testability)
//

import Foundation

/// Protocol for downloading models (enables dependency injection for testing)
protocol ModelDownloader: Sendable {
    /// Download a model to the specified directory
    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws

    /// Verify the downloaded model
    func verify(model: ModelIdentifier, at directory: URL) async -> Bool

    /// Check if model exists at path
    func exists(model: ModelIdentifier, at directory: URL) -> Bool
}

/// Default implementation that will integrate with actual download libraries
final class DefaultModelDownloader: ModelDownloader, @unchecked Sendable {

    // MARK: - Singleton

    static let shared = DefaultModelDownloader()

    private init() {}

    // MARK: - ModelDownloader

    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        // Ensure directory exists
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch model.category {
        case .asr:
            try await self.downloadASRModel(model, to: directory, progress: progress)
        case .llm:
            try await self.downloadLLMModel(model, to: directory, progress: progress)
        case .tts:
            try await self.downloadTTSModel(model, to: directory, progress: progress)
        }
    }

    func verify(model: ModelIdentifier, at directory: URL) async -> Bool {
        let fm = FileManager.default

        for file in model.requiredFiles {
            let filePath = directory.appendingPathComponent(file)
            // For .mlmodelc directories, check if it's a directory
            if file.hasSuffix(".mlmodelc") {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: filePath.path, isDirectory: &isDir) || !isDir.boolValue {
                    return false
                }
            } else {
                if !fm.fileExists(atPath: filePath.path) {
                    return false
                }
            }
        }

        return true
    }

    func exists(model: ModelIdentifier, at directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return false }

        // Check ALL required files to ensure model is complete
        for file in model.requiredFiles {
            let path = directory.appendingPathComponent(file)
            if file.hasSuffix(".mlmodelc") {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: path.path, isDirectory: &isDir) || !isDir.boolValue {
                    return false
                }
            } else {
                if !fm.fileExists(atPath: path.path) {
                    return false
                }
            }
        }

        return true
    }

    // MARK: - Private Download Implementations

    private func downloadASRModel(
        _ model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        // TODO: Integrate with FluidAudio SDK
        // let models = try await AsrModels.downloadAndLoad(
        //     to: directory,
        //     configuration: .defaultConfiguration(),
        //     version: .v3
        // )

        // For now, this is a placeholder that will be replaced when integrating FluidAudio
        // The actual download will be handled by the FluidAudio SDK
        throw ModelError.downloadFailed(model, "FluidAudio SDK integration not yet implemented")
    }

    private func downloadLLMModel(
        _ model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        // TODO: Integrate with MLX Swift's HuggingFace download utilities
        // let hub = HuggingFaceHub()
        // try await hub.download(repo: model.huggingFaceRepo, to: directory) { downloaded, total in
        //     let modelProgress = ModelDownloadProgress(
        //         identifier: model,
        //         bytesDownloaded: downloaded,
        //         totalBytes: total
        //     )
        //     progress(modelProgress)
        // }

        // Placeholder for MLX Swift integration
        throw ModelError.downloadFailed(model, "MLX Swift HuggingFace integration not yet implemented")
    }

    private func downloadTTSModel(
        _ model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        // TODO: Integrate with Kokoro Swift MLX HuggingFace download
        // Similar to LLM model download

        // Placeholder for Kokoro integration
        throw ModelError.downloadFailed(model, "Kokoro download integration not yet implemented")
    }
}

/// Mock downloader for testing
/// Note: This uses @unchecked Sendable because it's only used in tests
/// where we control the access patterns
final class MockModelDownloader: ModelDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldSucceed = true
    private var _downloadDelay: TimeInterval = 0.1
    private var _existingModels: Set<ModelIdentifier> = []
    private var _downloadedModels: [ModelIdentifier] = []

    var shouldSucceed: Bool {
        get { lock.withLock { _shouldSucceed } }
        set { lock.withLock { _shouldSucceed = newValue } }
    }

    var downloadDelay: TimeInterval {
        get { lock.withLock { _downloadDelay } }
        set { lock.withLock { _downloadDelay = newValue } }
    }

    var existingModels: Set<ModelIdentifier> {
        get { lock.withLock { _existingModels } }
        set { lock.withLock { _existingModels = newValue } }
    }

    var downloadedModels: [ModelIdentifier] {
        lock.withLock { _downloadedModels }
    }

    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let shouldSucceed = self.shouldSucceed
        let delay = self.downloadDelay

        guard shouldSucceed else {
            throw ModelError.downloadFailed(model, "Mock download failure")
        }

        // Simulate download progress
        for i in 1...10 {
            try await Task.sleep(for: .milliseconds(Int(delay * 100)))
            let progressValue = Double(i) / 10.0
            progress(ModelDownloadProgress(identifier: model, progress: progressValue))
        }

        lock.withLock {
            _downloadedModels.append(model)
            _existingModels.insert(model)
        }
    }

    func verify(model: ModelIdentifier, at directory: URL) async -> Bool {
        existingModels.contains(model)
    }

    func exists(model: ModelIdentifier, at directory: URL) -> Bool {
        existingModels.contains(model)
    }

    func reset() {
        lock.withLock {
            _downloadedModels = []
            _existingModels = []
        }
    }
}
