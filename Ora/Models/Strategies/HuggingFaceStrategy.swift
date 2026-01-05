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
        let filesToDownload = self.knownFiles(for: model)

        guard !filesToDownload.isEmpty else {
            throw ModelError.downloadFailed(model, "No files found in repository")
        }

        // Fetch actual file sizes from HuggingFace API for verification
        let expectedSizes = await self.fetchFileSizesFromAPI(repo: model.huggingFaceRepo, files: filesToDownload)
        
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

        // Verify download integrity
        self.logger.info("Verifying download for \(model.displayName)...")
        let verificationPassed = await self.verifyDownload(model: model, at: directory, expectedSizes: expectedSizes)
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

    /// Known files for each model type
    private func knownFiles(for model: ModelIdentifier) -> [String] {
        switch model {
        case .qwen3_4B:
            // Qwen 3 4B Instruct MLX model with chat template
            return [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "model.safetensors",
                "chat_template.jinja",  // Qwen 3 uses separate jinja file
            ]
            
        case .qwen7B, .qwen3B:
            // Legacy Qwen 2.5 models - MLX-community format
            return [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "model.safetensors",
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
    
    /// Fetch actual file sizes from HuggingFace API
    /// Returns a dictionary of filename -> size in bytes
    /// Falls back to empty dictionary if API call fails (verification will use minimum size checks)
    private func fetchFileSizesFromAPI(repo: String, files: [String]) async -> [String: Int64] {
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        
        do {
            let (data, response) = try await URLSession.shared.data(from: apiURL)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.logger.warning("HuggingFace API returned non-200 status, falling back to minimum size verification")
                return [:]
            }
            
            // Parse JSON response
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                self.logger.warning("Failed to parse HuggingFace API response")
                return [:]
            }
            
            var sizes: [String: Int64] = [:]
            for item in jsonArray {
                if let path = item["path"] as? String,
                   let size = item["size"] as? Int64,
                   files.contains(path) {
                    sizes[path] = size
                }
            }
            
            self.logger.debug("Fetched \(sizes.count) file sizes from HuggingFace API")
            return sizes
            
        } catch {
            self.logger.warning("Failed to fetch file sizes from HuggingFace API: \(error.localizedDescription)")
            return [:]
        }
    }
    
    /// Verify downloaded files match expected sizes
    /// Uses API-fetched sizes if available, otherwise falls back to minimum size checks
    private func verifyDownload(model: ModelIdentifier, at directory: URL, expectedSizes: [String: Int64]) async -> Bool {
        let fm = FileManager.default
        
        // Use API sizes if available, otherwise fall back to hardcoded sizes
        let sizesToCheck = expectedSizes.isEmpty ? model.expectedFileSizes : expectedSizes
        
        for file in model.requiredFiles {
            let filePath = directory.appendingPathComponent(file)
            
            // Check file exists
            guard fm.fileExists(atPath: filePath.path) else {
                self.logger.error("Verification failed: missing required file \(file)")
                return false
            }
            
            do {
                let attrs = try fm.attributesOfItem(atPath: filePath.path)
                let actualSize = attrs[.size] as? Int64 ?? 0
                
                if let expectedSize = sizesToCheck[file] {
                    // We have an expected size - use 99% threshold
                    let minimumSize = Int64(Double(expectedSize) * ModelIdentifier.minimumFileSizeThreshold)
                    if actualSize < minimumSize {
                        self.logger.error("Verification failed: \(file) is too small. Expected: \(expectedSize) bytes, Actual: \(actualSize) bytes")
                        return false
                    }
                } else {
                    // No expected size - use minimum reasonable sizes
                    let minimumReasonableSize = self.minimumReasonableSize(for: file)
                    if actualSize < minimumReasonableSize {
                        self.logger.error("Verification failed: \(file) is too small. Actual: \(actualSize) bytes, Minimum: \(minimumReasonableSize) bytes")
                        return false
                    }
                }
                
                self.logger.debug("Verified \(file): \(actualSize) bytes")
            } catch {
                self.logger.error("Verification failed: cannot read file attributes for \(file): \(error.localizedDescription)")
                return false
            }
        }
        
        return true
    }
    
    /// Minimum reasonable size for a file type (fallback when API unavailable)
    private func minimumReasonableSize(for file: String) -> Int64 {
        if file.hasSuffix(".safetensors") {
            // Model weights should be at least 100MB
            return 100_000_000
        } else if file.hasSuffix(".json") {
            // JSON files should be at least 100 bytes
            return 100
        } else if file.hasSuffix(".jinja") {
            // Template files should be at least 100 bytes
            return 100
        } else {
            // Other files - at least 10 bytes
            return 10
        }
    }
}
