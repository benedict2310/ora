//
//  BackgroundTaskPolicy.swift
//  Ora
//
//  Codable execution policy for persisted background tasks.
//

import Foundation

struct BackgroundTaskPolicy: Codable, Sendable, Equatable {
    static let defaultTaskKind = "research"
    static let defaultTimeoutSeconds = 120
    static let maximumTimeoutSeconds = 300

    let taskKind: String
    let timeoutSeconds: Int

    init(
        taskKind: String = BackgroundTaskPolicy.defaultTaskKind,
        timeoutSeconds: Int = BackgroundTaskPolicy.defaultTimeoutSeconds
    ) {
        let trimmedTaskKind = taskKind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.taskKind = trimmedTaskKind.isEmpty ? Self.defaultTaskKind : trimmedTaskKind
        self.timeoutSeconds = min(max(timeoutSeconds, 1), Self.maximumTimeoutSeconds)
    }
}
