//
//  MicrophonePermission.swift
//  Ora
//
//  Microphone permission handling
//

import AVFoundation
import os

struct MicrophonePermission: Sendable {

    private static let logger = Logger(subsystem: "com.ora.app", category: "MicrophonePermission")

    /// Check current authorization status
    static func checkStatus() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return mapStatus(status)
    }

    /// Request permission (async)
    static func request() async -> PermissionStatus {
        let currentStatus = checkStatus()

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
}
