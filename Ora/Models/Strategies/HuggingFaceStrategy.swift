//
//  HuggingFaceStrategy.swift
//  Ora
//
//  Download strategy for LLM and TTS models from HuggingFace
//

import Foundation
import os

/// Strategy for downloading LLM and TTS models from HuggingFace
struct HuggingFaceStrategy: ModelDownloadStrategy, Sendable {

    private let logger = Logger(subsystem: "com.ora.app", category: "HuggingFaceStrategy")
    private let downloader: FileDownloader

    init(downloader: FileDownloader = HuggingFaceDownloader()) {
        self.downloader = downloader
    }

    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        guard model.category == .llm || model.category == .tts else {
            throw ModelError.downloadFailed(model, "HuggingFaceStrategy only supports LLM and TTS models")
        }

        self.logger.info("Starting HuggingFace download for \(model.displayName) from \(model.huggingFaceRepo)")

        // Emit initial progress
        progress(ModelDownloadProgress(identifier: model, progress: 0.0))

        // Get list of files to download
        let filesToDownload = try await self.getFilesToDownload(for: model)

        guard !filesToDownload.isEmpty else {
            throw ModelError.downloadFailed(model, "No files found in repository")
        }

        self.logger.info("Found \(filesToDownload.count) files to download for \(model.displayName)")

        // Calculate total size for weighted progress
        let totalEstimatedBytes = model.estimatedSizeBytes
        var downloadedBytes: Int64 = 0

        // Download each file sequentially to avoid overwhelming the connection
        for (index, file) in filesToDownload.enumerated() {
            try Task.checkCancellation()

            guard let fileURL = HuggingFaceDownloader.fileURL(repo: model.huggingFaceRepo, path: file) else {
                throw ModelError.downloadFailed(model, "Invalid file URL: \(file)")
            }

            let destination = directory.appendingPathComponent(file)
            let fileEstimatedSize = self.estimateFileSize(file: file, model: model, totalFiles: filesToDownload.count)

            self.logger.debug("Downloading [\(index + 1)/\(filesToDownload.count)]: \(file)")

            let startBytes = downloadedBytes
            try await self.downloader.download(url: fileURL, to: destination) { fileProgress in
                // Calculate overall progress based on bytes
                let currentFileBytes = Int64(Double(fileEstimatedSize) * fileProgress)
                let totalDownloaded = startBytes + currentFileBytes
                let overallProgress = Double(totalDownloaded) / Double(totalEstimatedBytes)

                progress(ModelDownloadProgress(
                    identifier: model,
                    bytesDownloaded: totalDownloaded,
                    totalBytes: totalEstimatedBytes,
                    currentFile: file
                ))
            }

            downloadedBytes += fileEstimatedSize
        }

        // Verify download integrity by checking file sizes
        self.logger.info("Verifying download for \(model.displayName)...")
        let verificationPassed = await self.verifyDownload(model: model, at: directory)
        if !verificationPassed {
            self.logger.error("Download verification failed for \(model.displayName)")
            // Clean up partial/corrupted download
            try? FileManager.default.removeItem(at: directory)
            throw ModelError.downloadFailed(model, "Download verification failed - files may be corrupted or incomplete")
        }

        // Emit completion
        progress(ModelDownloadProgress(identifier: model, progress: 1.0))
        self.logger.info("HuggingFace download complete and verified for \(model.displayName)")
    }

    // MARK: - Private

    /// Get the list of files to download for a model
    private func getFilesToDownload(for model: ModelIdentifier) async throws -> [String] {
        // For known models, we have predefined file lists
        // This avoids an API call and handles models without public file listing
        return self.knownFiles(for: model)
    }

    /// Known files for each model type
    private func knownFiles(for model: ModelIdentifier) -> [String] {
        switch model {
        case .qwen7B, .qwen3B:
            // MLX-community Qwen models use standard MLX format
            return [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "model.safetensors",  // Single file for 4-bit quantized
            ]

        case .kokoro:
            // Kokoro TTS MLX model with default voice
            return [
                "config.json",
                "kokoro-v1_0.safetensors",
                "voices/af_heart.safetensors",  // Default voice (American female)
            ]

        case .parakeetTDT:
            // Parakeet is handled by FluidAudioStrategy, not this one
            return []
        }
    }

    /// Estimate file size based on model and file type
    private func estimateFileSize(file: String, model: ModelIdentifier, totalFiles: Int) -> Int64 {
        // Large files get proportionally more weight
        if file.hasSuffix(".safetensors") || file.hasSuffix(".bin") {
            // Model weights are ~95% of total size
            return Int64(Double(model.estimatedSizeBytes) * 0.95)
        } else {
            // Config/tokenizer files share remaining 5%
            let configCount = max(1, totalFiles - 1)
            return Int64(Double(model.estimatedSizeBytes) * 0.05 / Double(configCount))
        }
    }
    
    /// Verify downloaded files match expected sizes
    private func verifyDownload(model: ModelIdentifier, at directory: URL) async -> Bool {
        let fm = FileManager.default
        let expectedSizes = model.expectedFileSizes
        
        for file in model.requiredFiles {
            let filePath = directory.appendingPathComponent(file)
            
            // Check file exists
            guard fm.fileExists(atPath: filePath.path) else {
                self.logger.error("Verification failed: missing required file \(file)")
                return false
            }
            
            // Check file size if we have an expected size
            if let expectedSize = expectedSizes[file] {
                do {
                    let attrs = try fm.attributesOfItem(atPath: filePath.path)
                    let actualSize = attrs[.size] as? Int64 ?? 0
                    
                    // Reject files significantly smaller than expected
                    let minimumSize = Int64(Double(expectedSize) * ModelIdentifier.minimumFileSizeThreshold)
                    if actualSize < minimumSize {
                        self.logger.error("Verification failed: \(file) is too small. Expected: \(expectedSize) bytes, Actual: \(actualSize) bytes")
                        return false
                    }
                    
                    self.logger.debug("Verified \(file): \(actualSize) bytes (expected: \(expectedSize))")
                } catch {
                    self.logger.error("Verification failed: cannot read file attributes for \(file): \(error.localizedDescription)")
                    return false
                }
            }
        }
        
        return true
    }
}
