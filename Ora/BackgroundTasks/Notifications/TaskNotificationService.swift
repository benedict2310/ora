//
//  TaskNotificationService.swift
//  Ora
//
//  Authorization and delivery of local notifications for background task
//  completion and failure. Reuses the lazy-authorization pattern from
//  ModelMigrationCoordinator.
//

import Foundation
import UserNotifications
import os

// MARK: - Protocol

protocol TaskNotificationPosting: Sendable {
    func postCompletion(
        taskID: UUID,
        title: String,
        summaryPreview: String?,
        artifactPath: String?
    ) async

    func postFailure(
        taskID: UUID,
        title: String,
        errorDescription: String?
    ) async

    func removeAllPending() async
    func removeAllDelivered() async
}

// MARK: - TaskNotificationService

actor TaskNotificationService: TaskNotificationPosting {

    // MARK: - Constants

    static let categoryIdentifier = "com.ora.backgroundTask"
    static let showInFinderActionIdentifier = "com.ora.backgroundTask.showInFinder"
    static let artifactPathKey = "artifactPath"
    static let taskIDKey = "taskID"
    static let threadIdentifier = "ora-background-tasks"

    static let maxBodyLength = 200
    static let coalescingWindowSeconds: TimeInterval = 3.0

    // MARK: - Properties

    private let center: UNUserNotificationCenter
    private let logger = Logger.ora(category: "notifications")

    /// Pending completions waiting for the coalescing window to close.
    private struct PendingCompletion: Sendable {
        let taskID: UUID
        let title: String
        let summaryPreview: String?
        let artifactPath: String?
    }

    private var pendingCompletions: [PendingCompletion] = []
    private var coalescingTask: Task<Void, Never>?

    // MARK: - Init

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - Public API

    func postCompletion(
        taskID: UUID,
        title: String,
        summaryPreview: String?,
        artifactPath: String?
    ) async {
        let granted = await self.requestAuthorizationIfNeeded()
        guard granted else { return }

        let pending = PendingCompletion(
            taskID: taskID,
            title: title,
            summaryPreview: summaryPreview,
            artifactPath: artifactPath
        )

        self.enqueueCompletion(pending)
    }

    func postFailure(
        taskID: UUID,
        title: String,
        errorDescription: String?
    ) async {
        let granted = await self.requestAuthorizationIfNeeded()
        guard granted else { return }

        let body = Self.sanitizedBody(errorDescription ?? "The task failed.")

        let content = UNMutableNotificationContent()
        content.title = "Research failed"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = Self.threadIdentifier
        content.userInfo = [
            Self.taskIDKey: taskID.uuidString
        ]

        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier(for: taskID),
            content: content,
            trigger: nil
        )

        do {
            try await self.center.add(request)
        } catch {
            self.logger.warning("Failed to post failure notification: \(error.localizedDescription)")
        }
    }

    func removeAllPending() async {
        self.center.removeAllPendingNotificationRequests()
    }

    func removeAllDelivered() async {
        self.center.removeAllDeliveredNotifications()
    }

    // MARK: - Notification Categories

    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let showInFinderAction = UNNotificationAction(
            identifier: Self.showInFinderActionIdentifier,
            title: "Show in Finder",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [showInFinderAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
    }

    static func requestIdentifier(for taskID: UUID) -> String {
        return "ora-task-\(taskID.uuidString.lowercased())"
    }

    static func coalescedRequestIdentifier(for taskID: UUID) -> String {
        return Self.requestIdentifier(for: taskID) + "-coalesced"
    }

    // MARK: - Authorization

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await self.center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            self.logger.info("Notification permission denied; skipping delivery")
            return false
        case .notDetermined:
            do {
                let granted = try await self.center.requestAuthorization(options: [.alert, .sound])
                if !granted {
                    self.logger.info("User declined notification permission")
                }
                return granted
            } catch {
                self.logger.warning("Notification authorization request failed: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Coalescing

    private func enqueueCompletion(_ completion: PendingCompletion) {
        self.pendingCompletions.append(completion)
        self.coalescingTask?.cancel()

        self.coalescingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.coalescingWindowSeconds))
            } catch {
                return
            }
            await self?.flushPendingCompletions()
        }
    }

    private func flushPendingCompletions() async {
        let completions = self.pendingCompletions
        self.pendingCompletions.removeAll()
        self.coalescingTask = nil

        guard !completions.isEmpty else { return }

        if completions.count == 1 {
            await self.deliverSingleCompletion(completions[0])
        } else {
            await self.deliverCoalescedCompletion(completions)
        }
    }

    private func deliverSingleCompletion(_ completion: PendingCompletion) async {
        let body = Self.sanitizedBody(
            completion.summaryPreview ?? "Research complete."
        )

        let content = UNMutableNotificationContent()
        content.title = "Research complete"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = Self.threadIdentifier

        var userInfo: [String: String] = [
            Self.taskIDKey: completion.taskID.uuidString
        ]
        if let artifactPath = completion.artifactPath {
            userInfo[Self.artifactPathKey] = artifactPath
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier(for: completion.taskID),
            content: content,
            trigger: nil
        )

        do {
            try await self.center.add(request)
        } catch {
            self.logger.warning("Failed to post completion notification: \(error.localizedDescription)")
        }
    }

    private func deliverCoalescedCompletion(_ completions: [PendingCompletion]) async {
        let content = UNMutableNotificationContent()
        content.title = "\(completions.count) research tasks completed"
        content.body = "Tap to open Ora."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = Self.threadIdentifier

        // Use the first completion's artifact path for the Show in Finder action
        var userInfo: [String: String] = [
            Self.taskIDKey: completions[0].taskID.uuidString
        ]
        if let artifactPath = completions.first(where: { $0.artifactPath != nil })?.artifactPath {
            userInfo[Self.artifactPathKey] = artifactPath
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: Self.coalescedRequestIdentifier(for: completions[0].taskID),
            content: content,
            trigger: nil
        )

        do {
            try await self.center.add(request)
        } catch {
            self.logger.warning("Failed to post coalesced completion notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Sanitization

    static func sanitizedBody(_ text: String) -> String {
        let stripped = Self.stripControlCharacters(text)
        if stripped.count > Self.maxBodyLength {
            return String(stripped.prefix(Self.maxBodyLength - 1)) + "\u{2026}"
        }
        return stripped
    }

    static func stripControlCharacters(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            // Allow normal printable characters, tabs, and newlines
            if scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
