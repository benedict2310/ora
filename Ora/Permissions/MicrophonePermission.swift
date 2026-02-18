//
//  MicrophonePermission.swift
//  Ora
//
//  Microphone permission handling
//

import AVFoundation
import os

struct MicrophonePermission: Sendable {

    private static let logger = Logger.ora(category: "MicrophonePermission")

    /// Check current authorization status
    static func checkStatus() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return mapStatus(status)
    }

    /// Request permission (async)
    static func request() async -> PermissionStatus {
        let currentStatus = checkStatus()

        if currentStatus == .notDetermined, shouldSkipPermissionPrompts {
            logger.info("Skipping microphone permission prompt during tests")
            return .notDetermined
        }

        guard currentStatus == .notDetermined else {
            logger.debug("Microphone permission already determined: \(String(describing: currentStatus))")
            return currentStatus
        }

        logger.info("Requesting microphone permission...")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        let newStatus: PermissionStatus = granted ? .authorized : .denied
        logger.info("Microphone permission: \(granted ? "granted" : "denied")")
        return newStatus
    }

    private static func mapStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static var shouldSkipPermissionPrompts: Bool {
        let env = ProcessInfo.processInfo.environment
        if let override = env["ORA_SKIP_PERMISSION_PROMPTS"]?.lowercased() {
            return override == "1" || override == "true"
        }
        if env["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTest") != nil
    }
}
