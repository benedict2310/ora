//
//  ContainerWorker.swift
//  Ora
//
//  BackgroundWorker conformance that dispatches tasks to an isolated container.
//

import Foundation
import os

struct ContainerWorker: BackgroundWorker {

    // MARK: - Properties

    private let runtime: any ContainerRuntime
    private let io: ContainerIO
    private let imageManager: ContainerImageManager
    private let logger = Logger.ora(category: "container")

    // MARK: - Init

    init(
        runtime: any ContainerRuntime,
        io: ContainerIO = ContainerIO(),
        imageManager: ContainerImageManager = ContainerImageManager()
    ) {
        self.runtime = runtime
        self.io = io
        self.imageManager = imageManager
    }

    // MARK: - BackgroundWorker

    func execute(
        taskID: UUID,
        input: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy
    ) async throws -> WorkerResult {
        // 1. Create temp shared directory
        let sharedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-container-\(taskID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedDirectory,
            withIntermediateDirectories: true
        )

        defer {
            self.io.cleanupSharedDirectory(sharedDirectory)
        }

        // 2. Build and write input.json
        let constraints = ContainerInputConstraints(
            maxSearchQueries: 5,
            maxPages: 15,
            maxDomains: 8,
            maxPageSizeBytes: 5_242_880,
            timeoutSeconds: policy.timeoutSeconds
        )

        let containerInput = ContainerInput(
            taskID: taskID.uuidString,
            query: input.query,
            urls: input.urls,
            constraints: constraints
        )

        try self.io.writeInput(containerInput, to: sharedDirectory)

        // 3. Build configuration
        let imagePath = self.imageManager.imageURL ?? URL(fileURLWithPath: "/missing-image")
        let configuration = ContainerConfiguration(
            imagePath: imagePath,
            sharedDirectoryPath: sharedDirectory,
            timeoutSeconds: policy.timeoutSeconds
        )

        // 4. Start container
        let handle: ContainerHandle
        do {
            handle = try await self.runtime.start(configuration: configuration)
        } catch {
            throw ContainerRuntimeError.startFailed(reason: error.localizedDescription)
        }

        self.logger.info("Container \(handle.id) started for task \(taskID)")

        // 5. Wait for exit with cancellation support
        do {
            try await withTaskCancellationHandler {
                let exitStatus = try await self.runtime.waitForExit(handle: handle)

                guard exitStatus.exitCode == 0 else {
                    throw ContainerRuntimeError.containerFailed(
                        exitCode: exitStatus.exitCode,
                        stderr: exitStatus.stderr
                    )
                }
            } onCancel: {
                Task {
                    try? await self.runtime.kill(handle: handle)
                    self.logger.info("Container \(handle.id) killed due to task cancellation")
                }
            }
        } catch is CancellationError {
            try? await self.runtime.kill(handle: handle)
            throw CancellationError()
        }

        // 6. Read output.json
        let output = try self.io.readOutput(from: sharedDirectory)

        // 7. Map to WorkerResult
        let workerResult = self.io.mapToWorkerResult(
            output: output,
            taskID: taskID,
            taskKind: policy.taskKind
        )

        self.logger.info("Container \(handle.id) completed: \(workerResult.pages.count) pages fetched")

        return workerResult
    }
}
