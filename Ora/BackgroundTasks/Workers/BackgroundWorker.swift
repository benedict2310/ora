//
//  BackgroundWorker.swift
//  Ora
//
//  Shared worker contract for background task execution.
//

import Foundation

protocol BackgroundWorker: Sendable {
    func execute(
        taskID: UUID,
        input: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy
    ) async throws -> WorkerResult
}
