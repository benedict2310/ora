//
//  BackgroundTaskRecord.swift
//  Ora
//
//  SwiftData model for background task lifecycle state.
//

import Foundation
import SwiftData

struct BackgroundTaskRecordSnapshot: Sendable, Equatable {
    let id: UUID
    let taskKind: String
    let inputs: BackgroundTaskInputs
    let policy: BackgroundTaskPolicy
    let state: BackgroundTaskState
    let summaryState: BackgroundTaskSummaryState?
    let artifactPath: String?
    let errorMessage: String?
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let sessionID: UUID?
}

@Model
final class BackgroundTaskRecord {

    @Attribute(.unique) var id: UUID
    var taskKind: String
    var inputsData: Data
    var policyData: Data
    var stateRawValue: String
    var summaryStateRawValue: String?
    var artifactPath: String?
    var errorMessage: String?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var sessionID: UUID?

    init(
        id: UUID = UUID(),
        inputs: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy,
        sessionID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskKind = policy.taskKind
        self.inputsData = (try? JSONEncoder().encode(inputs)) ?? Data()
        self.policyData = (try? JSONEncoder().encode(policy)) ?? Data()
        self.stateRawValue = BackgroundTaskState.queued.rawValue
        self.summaryStateRawValue = nil
        self.artifactPath = nil
        self.errorMessage = nil
        self.createdAt = createdAt
        self.startedAt = nil
        self.completedAt = nil
        self.sessionID = sessionID
    }

    var state: BackgroundTaskState {
        get {
            BackgroundTaskState(rawValue: self.stateRawValue) ?? .failed
        }
        set {
            self.stateRawValue = newValue.rawValue
        }
    }

    var summaryState: BackgroundTaskSummaryState? {
        get {
            guard let summaryStateRawValue else {
                return nil
            }
            return BackgroundTaskSummaryState(rawValue: summaryStateRawValue)
        }
        set {
            self.summaryStateRawValue = newValue?.rawValue
        }
    }

    func decodeInputs() throws -> BackgroundTaskInputs {
        return try JSONDecoder().decode(BackgroundTaskInputs.self, from: self.inputsData)
    }

    func decodePolicy() throws -> BackgroundTaskPolicy {
        return try JSONDecoder().decode(BackgroundTaskPolicy.self, from: self.policyData)
    }

    func update(inputs: BackgroundTaskInputs) {
        self.inputsData = (try? JSONEncoder().encode(inputs)) ?? Data()
    }

    func update(policy: BackgroundTaskPolicy) {
        self.taskKind = policy.taskKind
        self.policyData = (try? JSONEncoder().encode(policy)) ?? Data()
    }

    func snapshot() throws -> BackgroundTaskRecordSnapshot {
        return BackgroundTaskRecordSnapshot(
            id: self.id,
            taskKind: self.taskKind,
            inputs: try self.decodeInputs(),
            policy: try self.decodePolicy(),
            state: self.state,
            summaryState: self.summaryState,
            artifactPath: self.artifactPath,
            errorMessage: self.errorMessage,
            createdAt: self.createdAt,
            startedAt: self.startedAt,
            completedAt: self.completedAt,
            sessionID: self.sessionID
        )
    }
}
