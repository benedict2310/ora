//
//  ModelDownloading.swift
//  Ora
//
//  Protocol for model downloaders and download strategies
//

import Foundation
import os

// MARK: - ModelDownloader Protocol

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

// MARK: - ModelDownloadStrategy Protocol

/// Strategy protocol for downloading specific model types
protocol ModelDownloadStrategy: Sendable {
    /// Download a model to the specified directory
    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws
}

// MARK: - DefaultModelDownloader

/// Default implementation that delegates to appropriate strategies based on model category
final class DefaultModelDownloader: ModelDownloader, @unchecked Sendable {

    // MARK: - Singleton

    static let shared = DefaultModelDownloader()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "ModelDownloader")
    private let asrStrategy: ModelDownloadStrategy
    private let huggingFaceStrategy: ModelDownloadStrategy

    // MARK: - Initialization

    private init() {
        self.asrStrategy = FluidAudioStrategy()
        self.huggingFaceStrategy = HuggingFaceStrategy()
    }

    /// Create with custom strategies (for testing)
    init(asrStrategy: ModelDownloadStrategy, huggingFaceStrategy: ModelDownloadStrategy) {
        self.asrStrategy = asrStrategy
        self.huggingFaceStrategy = huggingFaceStrategy
    }

    // MARK: - ModelDownloader

    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        // Ensure directory exists
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.logger.info("Starting download for \(model.displayName) using \(model.category.rawValue) strategy")

        // Select strategy based on model category
        let strategy = self.strategy(for: model.category)
        try await strategy.download(model: model, to: directory, progress: progress)
    }

    func verify(model: ModelIdentifier, at directory: URL) async -> Bool {
        let fm = FileManager.default
        let expectedSizes = model.expectedFileSizes

        for file in model.requiredFiles {
            let filePath = directory.appendingPathComponent(file)
            
            // For .mlmodelc directories, check if it's a directory
            if file.hasSuffix(".mlmodelc") {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: filePath.path, isDirectory: &isDir) || !isDir.boolValue {
                    self.logger.warning("Verification failed: missing \(file)")
                    return false
                }
            } else {
                // Check file exists
                if !fm.fileExists(atPath: filePath.path) {
                    self.logger.warning("Verification failed: missing \(file)")
                    return false
                }
                
                // Check file size if we have an expected size
                if let expectedSize = expectedSizes[file] {
                    do {
                        let attrs = try fm.attributesOfItem(atPath: filePath.path)
                        let actualSize = attrs[.size] as? Int64 ?? 0
                        
                        // Reject files that are significantly smaller than expected
                        let minimumSize = Int64(Double(expectedSize) * ModelIdentifier.minimumFileSizeThreshold)
                        if actualSize < minimumSize {
                            self.logger.error("Verification failed: \(file) is too small. Expected: \(expectedSize) bytes, Actual: \(actualSize) bytes (minimum: \(minimumSize))")
                            return false
                        }
                        
                        // Also reject files significantly larger (may indicate corruption or wrong file)
                        let maximumSize = Int64(Double(expectedSize) * 1.05)  // 5% tolerance
                        if actualSize > maximumSize {
                            self.logger.warning("Verification warning: \(file) is larger than expected. Expected: \(expectedSize) bytes, Actual: \(actualSize) bytes")
                            // Don't fail on larger files, just warn (model may have been updated)
                        }
                        
                        self.logger.debug("Verified \(file): \(actualSize) bytes (expected: \(expectedSize))")
                    } catch {
                        self.logger.error("Verification failed: cannot read attributes for \(file): \(error.localizedDescription)")
                        return false
                    }
                }
            }
        }

        self.logger.debug("Verification passed for \(model.displayName)")
        return true
    }

    func exists(model: ModelIdentifier, at directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return false }

        let expectedSizes = model.expectedFileSizes
        
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
                
                // Check file size if we have an expected size
                if let expectedSize = expectedSizes[file] {
                    do {
                        let attrs = try fm.attributesOfItem(atPath: path.path)
                        let actualSize = attrs[.size] as? Int64 ?? 0
                        let minimumSize = Int64(Double(expectedSize) * ModelIdentifier.minimumFileSizeThreshold)
                        if actualSize < minimumSize {
                            // File is too small - treat as not existing (corrupted)
                            return false
                        }
                    } catch {
                        return false
                    }
                }
            }
        }

        return true
    }

    // MARK: - Private

    private func strategy(for category: ModelCategory) -> ModelDownloadStrategy {
        switch category {
        case .asr:
            return self.asrStrategy
        case .llm, .tts:
            return self.huggingFaceStrategy
        }
    }
}

// MARK: - MockModelDownloader

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

// MARK: - MockModelDownloadStrategy

/// Mock strategy for testing individual strategy behavior
final class MockModelDownloadStrategy: ModelDownloadStrategy, @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldSucceed = true
    private var _downloadDelay: TimeInterval = 0.1
    private var _downloadedModels: [ModelIdentifier] = []

    var shouldSucceed: Bool {
        get { lock.withLock { _shouldSucceed } }
        set { lock.withLock { _shouldSucceed = newValue } }
    }

    var downloadDelay: TimeInterval {
        get { lock.withLock { _downloadDelay } }
        set { lock.withLock { _downloadDelay = newValue } }
    }

    var downloadedModels: [ModelIdentifier] {
        lock.withLock { _downloadedModels }
    }

    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        guard self.shouldSucceed else {
            throw ModelError.downloadFailed(model, "Mock strategy failure")
        }

        // Simulate download progress
        for i in 1...10 {
            try await Task.sleep(for: .milliseconds(Int(self.downloadDelay * 100)))
            let progressValue = Double(i) / 10.0
            progress(ModelDownloadProgress(identifier: model, progress: progressValue))
        }

        lock.withLock {
            _downloadedModels.append(model)
        }
    }

    func reset() {
        lock.withLock {
            _downloadedModels = []
        }
    }
}
