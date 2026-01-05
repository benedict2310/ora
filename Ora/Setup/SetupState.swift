//
//  SetupState.swift
//  Ora
//
//  First-run setup state management
//

import Foundation

/// Steps in the setup flow
enum SetupStep: Int, CaseIterable, Sendable {
    case welcome = 0
    case permissions = 1
    case modelExplanation = 2
    case download = 3
    case ready = 4

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .modelExplanation: return "Models"
        case .download: return "Download"
        case .ready: return "Ready"
        }
    }

    var canGoBack: Bool {
        switch self {
        case .welcome: return false
        case .permissions: return true
        case .modelExplanation: return true
        case .download: return false // Can't go back during active download
        case .ready: return false
        }
    }
}

/// Download state for an individual model
enum ModelDownloadState: Sendable, Equatable {
    case pending
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case verifying
    case complete
    case error(String)

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    var progress: Double {
        switch self {
        case .pending: return 0
        case .downloading(let progress, _, _): return progress
        case .verifying: return 1.0
        case .complete: return 1.0
        case .error: return 0
        }
    }
}

/// Aggregated setup state
struct SetupState: Sendable {
    var currentStep: SetupStep = .welcome
    var isComplete: Bool = false

    // Permissions
    var permissionsGranted: Bool = false
    var skippedOptionalPermissions: Bool = false

    // Downloads
    var downloadProgress: Double = 0
    var downloadingModel: String? = nil
    var downloadError: String? = nil
    var modelProgresses: [ModelIdentifier: Double] = [:]
    var primaryLLM: ModelIdentifier = .qwen3_4B  // The actual LLM being downloaded

    // Enhanced download stats
    var modelDownloadStates: [ModelIdentifier: ModelDownloadState] = [:]
    var totalBytesDownloaded: Int64 = 0
    var totalBytesToDownload: Int64 = 0
    var downloadSpeedBytesPerSecond: Double = 0
    var estimatedTimeRemainingSeconds: TimeInterval? = nil
    var isDownloading: Bool = false
    var downloadWasCancelled: Bool = false

    // System info
    var systemRAMGB: Int = 0
    var recommendedModel: String = "Qwen 3 4B"

    // MARK: - Computed Properties

    /// Formatted bytes downloaded (e.g., "1.7 GB")
    var formattedBytesDownloaded: String {
        Self.formatBytes(self.totalBytesDownloaded)
    }

    /// Formatted total bytes (e.g., "3.6 GB")
    var formattedTotalBytes: String {
        Self.formatBytes(self.totalBytesToDownload)
    }

    /// Formatted download speed (e.g., "12.3 MB/s")
    var formattedDownloadSpeed: String {
        let speedMBps = self.downloadSpeedBytesPerSecond / (1024 * 1024)
        if speedMBps < 0.1 {
            return "..."
        }
        return String(format: "%.1f MB/s", speedMBps)
    }

    /// Formatted estimated time remaining (e.g., "~2 min left")
    var formattedTimeRemaining: String? {
        guard let seconds = self.estimatedTimeRemainingSeconds, seconds > 0 else {
            return nil
        }
        if seconds < 60 {
            return "~\(Int(seconds))s left"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "~\(minutes) min left"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes > 0 {
                return "~\(hours)h \(minutes)m left"
            }
            return "~\(hours)h left"
        }
    }

    /// Total size of all models to download (for display)
    static var totalModelSizeDisplay: String {
        // Parakeet (~600 MB) + Qwen 3 4B (~2.5 GB) + Kokoro (~500 MB) ≈ 3.6 GB
        return "~3.6 GB"
    }

    // MARK: - Helpers

    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let setupDidComplete = Notification.Name("setupDidComplete")
}
