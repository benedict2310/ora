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

/// Aggregated setup state
struct SetupState: Sendable {
    var currentStep: SetupStep = .welcome
    var isComplete: Bool = false

    // Permissions
    var permissionsGranted: Bool = false
    var skippedOptionalPermissions: Bool = false

    // Downloads - ONLY setup-specific state, progress tracked in ModelsState
    var downloadProgress: Double = 0  // Overall progress for backward compatibility
    var downloadingModel: String? = nil  // Currently downloading model name
    var downloadError: String? = nil  // Error message
    var primaryLLM: ModelIdentifier = .qwen3_4B  // The actual LLM being downloaded
    var downloadWasCancelled: Bool = false  // Cancellation flag

    // System info
    var systemRAMGB: Int = 0
    var recommendedModel: String = "Qwen 3 4B"

    // MARK: - Helpers

    /// Format bytes to human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    /// Total size of all models to download (for display)
    static var totalModelSizeDisplay: String {
        // Parakeet (~600 MB) + Qwen 3 4B (~2.5 GB) + Kokoro (~500 MB) ≈ 3.6 GB
        return "~3.6 GB"
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let setupDidComplete = Notification.Name("setupDidComplete")
}
