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
    case download = 2
    case ready = 3

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .download: return "Download Models"
        case .ready: return "Ready"
        }
    }

    var canGoBack: Bool {
        switch self {
        case .welcome: return false
        case .permissions: return true
        case .download: return false // Can't go back during download
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

    // Downloads
    var downloadProgress: Double = 0
    var downloadingModel: String? = nil
    var downloadError: String? = nil
    var modelProgresses: [ModelIdentifier: Double] = [:]
    var primaryLLM: ModelIdentifier = .qwen3_4B  // The actual LLM being downloaded

    // System info
    var systemRAMGB: Int = 0
    var recommendedModel: String = "Qwen 3 4B"
}

// MARK: - Notifications

extension Notification.Name {
    static let setupDidComplete = Notification.Name("setupDidComplete")
}
