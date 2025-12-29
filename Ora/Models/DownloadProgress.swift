//
//  DownloadProgress.swift
//  Ora
//
//  Download progress tracking types
//

import Foundation

/// Progress update for a single model download
struct ModelDownloadProgress: Sendable {
    let identifier: ModelIdentifier
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let progress: Double // 0.0 - 1.0
    let currentFile: String?

    var progressPercent: Int {
        Int(progress * 100)
    }

    init(
        identifier: ModelIdentifier,
        bytesDownloaded: Int64,
        totalBytes: Int64,
        currentFile: String? = nil
    ) {
        self.identifier = identifier
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.progress = totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0
        self.currentFile = currentFile
    }

    /// Create a progress update with a percentage (0.0 - 1.0)
    init(identifier: ModelIdentifier, progress: Double, currentFile: String? = nil) {
        self.identifier = identifier
        self.progress = min(max(progress, 0), 1)
        self.bytesDownloaded = Int64(Double(identifier.estimatedSizeBytes) * self.progress)
        self.totalBytes = identifier.estimatedSizeBytes
        self.currentFile = currentFile
    }
}

/// Aggregated progress for all downloads
struct OverallDownloadProgress: Sendable {
    let models: [ModelIdentifier: ModelDownloadProgress]
    let overallProgress: Double
    let estimatedTimeRemaining: TimeInterval?

    var overallPercent: Int {
        Int(overallProgress * 100)
    }

    /// Calculate overall progress from individual model progress
    static func calculate(
        from progressMap: [ModelIdentifier: ModelDownloadProgress],
        models: [ModelIdentifier]
    ) -> OverallDownloadProgress {
        var totalBytes: Int64 = 0
        var downloadedBytes: Int64 = 0

        for model in models {
            if let progress = progressMap[model] {
                totalBytes += progress.totalBytes
                downloadedBytes += progress.bytesDownloaded
            } else {
                totalBytes += model.estimatedSizeBytes
            }
        }

        let overall = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0

        return OverallDownloadProgress(
            models: progressMap,
            overallProgress: overall,
            estimatedTimeRemaining: nil
        )
    }
}
