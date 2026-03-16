//
//  TaskNotificationDelegate.swift
//  Ora
//
//  Handles user interaction with background-task notifications:
//  default click activates Ora, Show in Finder reveals artifact path.
//

import AppKit
import UserNotifications
import os

final class TaskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    // MARK: - Properties

    private let logger = Logger.ora(category: "notifications")
    private let artifactRootProvider: @Sendable () throws -> URL

    // MARK: - Init

    init(artifactRootProvider: @escaping @Sendable () throws -> URL = {
        try ArtifactLayout.defaultRootURL()
    }) {
        self.artifactRootProvider = artifactRootProvider
        super.init()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification is delivered while Ora is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// Called when the user interacts with a notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case TaskNotificationService.showInFinderActionIdentifier:
            self.handleShowInFinder(userInfo: userInfo)

        case UNNotificationDefaultActionIdentifier:
            // Default click: activate Ora
            await MainActor.run {
                NSApp.activate()
            }

        default:
            break
        }
    }

    // MARK: - Show in Finder

    private func handleShowInFinder(userInfo: [AnyHashable: Any]) {
        guard let artifactPath = userInfo[TaskNotificationService.artifactPathKey] as? String else {
            self.logger.info("Show in Finder action: no artifact path in notification")
            return
        }

        guard self.isPathWithinArtifactRoot(artifactPath) else {
            self.logger.warning("Show in Finder action: artifact path outside allowed root, ignoring")
            return
        }

        let url = URL(fileURLWithPath: artifactPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Path Validation

    func isPathWithinArtifactRoot(_ path: String) -> Bool {
        let rootURL: URL
        do {
            rootURL = try self.artifactRootProvider()
        } catch {
            self.logger.error("Failed to resolve artifact root for path validation: \(error.localizedDescription)")
            return false
        }

        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        return standardizedPath == rootPath || standardizedPath.hasPrefix(rootPrefix)
    }
}
