//
//  BackgroundTaskState.swift
//  Ora
//
//  Lifecycle states for persisted background tasks.
//

import Foundation

enum BackgroundTaskState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case canceled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled:
            return true
        case .queued, .running:
            return false
        }
    }

    func canTransition(to nextState: BackgroundTaskState) -> Bool {
        switch (self, nextState) {
        case (.queued, .running), (.queued, .canceled):
            return true
        case (.running, .completed), (.running, .failed), (.running, .canceled):
            return true
        default:
            return false
        }
    }
}

enum BackgroundTaskSummaryState: String, Codable, Sendable, CaseIterable {
    case pending
    case completed
    case failed
}
