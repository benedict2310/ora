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
    var primaryLLM: ModelIdentifier = .recommendedLocalLLM()  // The actual LLM being downloaded
    var downloadWasCancelled: Bool = false  // Cancellation flag

    // System info
    var systemRAMGB: Int = 0
    var recommendedModel: String = ModelIdentifier.recommendedLocalLLM().displayName

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
        return totalModelSizeDisplay(for: .recommendedLocalLLM())
    }

    static func totalModelSizeDisplay(for primaryLLM: ModelIdentifier) -> String {
        let totalBytes =
            ModelIdentifier.parakeetTDT.estimatedSizeBytes
            + primaryLLM.estimatedSizeBytes
            + ModelIdentifier.kokoro.estimatedSizeBytes
        let totalGB = Double(totalBytes) / 1_000_000_000
        return String(format: "~%.1f GB", totalGB)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let setupDidComplete = Notification.Name("setupDidComplete")
}
