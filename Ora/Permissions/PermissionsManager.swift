//
//  PermissionsManager.swift
//  Ora
//
//  Centralized permission state management
//

import Foundation
import AppKit
import os

/// Notification posted when permission state changes
extension Notification.Name {
    static let permissionsStateDidChange = Notification.Name("permissionsStateDidChange")
}

/// Centralized manager for all app permissions
actor PermissionsManager {

    // MARK: - Singleton

    static let shared = PermissionsManager()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "PermissionsManager")
    private let client: PermissionsClient
    private var _state = PermissionsState()
    private static let skipPromptEnvKey = "ORA_SKIP_PERMISSION_PROMPTS"

    /// Current permission state
    var state: PermissionsState {
        _state
    }

    // MARK: - Initialization

    private init() {
        self.client = LivePermissionsClient()
    }

    /// Initialize with a custom client (for testing)
    init(client: PermissionsClient) {
        self.client = client
    }

    // MARK: - Public API

    /// Refresh all permission statuses
    func refreshAll() async {
        logger.debug("Refreshing all permission statuses...")

        for type in PermissionType.allCases {
            _state[type] = client.checkStatus(for: type)
        }

        await postStateChange()

        logger.info("Permissions refreshed: required=\(self._state.requiredPermissionsGranted)")
    }

    /// Check status of a specific permission
    func check(_ type: PermissionType) async -> PermissionStatus {
        let status = client.checkStatus(for: type)
        _state[type] = status
        await postStateChange()
        return status
    }

    /// Request a specific permission
    func request(_ type: PermissionType) async -> PermissionStatus {
        logger.info("Requesting permission: \(type.rawValue)")

        let currentStatus = client.checkStatus(for: type)
        if currentStatus == .notDetermined,
           Self.shouldSkipPermissionPrompts,
           client is LivePermissionsClient {
            logger.info("Skipping permission prompt for \(type.rawValue) during tests")
            _state[type] = .notDetermined
            await postStateChange()
            return .notDetermined
        }

        let shouldTrackPrompt = currentStatus == .notDetermined
        if shouldTrackPrompt {
            await PermissionPromptTracker.shared.beginPrompt(for: type)
        }

        let status = await client.request(type)
        _state[type] = status

        await postStateChange()

        if shouldTrackPrompt {
            await PermissionPromptTracker.shared.endPrompt(for: type)
        }
        return status
    }

    /// Request all required permissions
    func requestRequired() async -> Bool {
        _ = await request(.microphone)
        return _state.requiredPermissionsGranted
    }

    /// Request all optional permissions
    func requestOptional() async {
        _ = await request(.calendar)
        _ = await request(.reminders)
        _ = await request(.contacts)
    }

    /// Open System Settings for a permission
    @MainActor
    func openSettings(for type: PermissionType) {
        client.openSettings(for: type)
    }

    // MARK: - Private

    private func postStateChange() async {
        let currentState = _state
        await MainActor.run {
            NotificationCenter.default.post(
                name: .permissionsStateDidChange,
                object: currentState
            )
        }
    }

    private static var shouldSkipPermissionPrompts: Bool {
        let env = ProcessInfo.processInfo.environment
        if let override = env[skipPromptEnvKey]?.lowercased() {
            return override == "1" || override == "true"
        }
        if env["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTest") != nil
    }
}
