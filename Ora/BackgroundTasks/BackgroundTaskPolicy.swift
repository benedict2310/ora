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
    let workerBackend: WorkerBackend

    init(
        taskKind: String = BackgroundTaskPolicy.defaultTaskKind,
        timeoutSeconds: Int = BackgroundTaskPolicy.defaultTimeoutSeconds,
        workerBackend: WorkerBackend = .auto
    ) {
        let trimmedTaskKind = taskKind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.taskKind = trimmedTaskKind.isEmpty ? Self.defaultTaskKind : trimmedTaskKind
        self.timeoutSeconds = min(max(timeoutSeconds, 1), Self.maximumTimeoutSeconds)
        self.workerBackend = workerBackend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.taskKind = try container.decode(String.self, forKey: .taskKind)
        self.timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
        self.workerBackend = try container.decodeIfPresent(WorkerBackend.self, forKey: .workerBackend) ?? .auto
    }
}

/// Worker backend preference for task execution.
enum WorkerBackend: String, Codable, Sendable, Equatable {
    /// Use container if available, else in-process.
    case auto
    /// Require container; fail if unavailable.
    case container
    /// Force in-process (existing behavior).
    case inProcess
}
