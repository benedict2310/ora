//
//  ScreenshotCaptureService.swift
//  Ora
//
//  One-shot screenshot capture using ScreenCaptureKit.
//

import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import AppKit
import os

protocol ScreenshotCapturing: Sendable {
    func captureScreenshotPNG() async throws -> Data
    @MainActor func openScreenRecordingSettings()
}

protocol ScreenCaptureAccessControlling: Sendable {
    func preflightAccess() -> Bool
    func requestAccess() -> Bool
}

struct LiveScreenCaptureAccessController: ScreenCaptureAccessControlling {
    func preflightAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

enum ScreenshotCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case noDisplayAvailable
    case captureFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen capture permission was denied."
        case .noDisplayAvailable:
            return "Ora could not find a display to capture."
        case .captureFailed:
            return "Ora could not capture a screenshot."
        case .encodingFailed:
            return "Ora could not prepare the screenshot attachment."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Enable Ora in System Settings > Privacy & Security > Screen Recording."
        case .noDisplayAvailable, .captureFailed, .encodingFailed:
            return nil
        }
    }
}

final class ScreenshotCaptureService: ScreenshotCapturing {

    // MARK: - Singleton

    static let shared = ScreenshotCaptureService()

    // MARK: - Constants

    static let screenRecordingSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    // MARK: - Properties

    private let logger = Logger.ora(category: "ScreenshotCapture")
    private let accessController: any ScreenCaptureAccessControlling

    // MARK: - Initialization

    init(accessController: any ScreenCaptureAccessControlling = LiveScreenCaptureAccessController()) {
        self.accessController = accessController
    }

    // MARK: - Public API

    func captureScreenshotPNG() async throws -> Data {
        let preflightGranted = self.accessController.preflightAccess()
        if !preflightGranted {
            let requestedGranted = self.accessController.requestAccess()
            guard requestedGranted else {
                self.logger.notice("SCREENSHOT_CAPTURE_PERMISSION_DENIED")
                throw ScreenshotCaptureError.permissionDenied
            }
        }

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            self.logger.error("Failed to fetch shareable content: \(error.localizedDescription)")
            throw ScreenshotCaptureError.captureFailed
        }

        guard let display = shareableContent.displays.first else {
            throw ScreenshotCaptureError.noDisplayAvailable
        }

        let contentFilter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = true

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)
        } catch {
            self.logger.error("Screen capture failed: \(error.localizedDescription)")
            throw ScreenshotCaptureError.captureFailed
        }

        guard let pngData = Self.encodePNG(from: cgImage) else {
            throw ScreenshotCaptureError.encodingFailed
        }

        return pngData
    }

    @MainActor
    func openScreenRecordingSettings() {
        guard let settingsURL = URL(string: Self.screenRecordingSettingsURL) else {
            return
        }
        NSWorkspace.shared.open(settingsURL)
    }

    // MARK: - Private

    private static func encodePNG(from image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }
}
