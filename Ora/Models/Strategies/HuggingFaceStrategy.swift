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

        // Emit completion
        progress(ModelDownloadProgress(identifier: model, progress: 1.0))
        self.logger.info("HuggingFace download complete for \(model.displayName)")
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
            // Kokoro TTS MLX model
            return [
                "config.json",
                "model.safetensors",
                "voices.json",
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
}
