//
//  BackgroundTaskEvent.swift
//  Ora
//
//  Observer payloads emitted by BackgroundTaskManager.
//

import Foundation

struct BackgroundTaskEvent: Sendable, Equatable {
    let sequenceNumber: UInt64
    let taskID: UUID
    let timestamp: Date
    let fromState: BackgroundTaskState?
    let toState: BackgroundTaskState
    let record: BackgroundTaskRecordSnapshot
}
