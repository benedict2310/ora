//
//  ContainerRuntime.swift
//  Ora
//
//  Protocol defining the container runtime lifecycle contract.
//

import Foundation

/// Opaque handle returned by a runtime to identify a running container.
struct ContainerHandle: Sendable, Equatable {
    let id: String
    let sharedDirectoryURL: URL
}

/// Exit status of a completed container.
struct ContainerExitStatus: Sendable, Equatable {
    let exitCode: Int32
    let stderr: String?
}

/// Errors surfaced by the container runtime layer.
enum ContainerRuntimeError: LocalizedError, Equatable, Sendable {
    case runtimeUnavailable
    case imageNotFound(path: String)
    case imageValidationFailed(reason: String)
    case startFailed(reason: String)
    case containerTimedOut(seconds: Int)
    case containerFailed(exitCode: Int32, stderr: String?)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Container runtime is not available on this system."
        case .imageNotFound(let path):
            return "Container image not found at: \(path)"
        case .imageValidationFailed(let reason):
            return "Container image validation failed: \(reason)"
        case .startFailed(let reason):
            return "Container failed to start: \(reason)"
        case .containerTimedOut(let seconds):
            return "Container exceeded timeout of \(seconds) seconds."
        case .containerFailed(let exitCode, let stderr):
            let detail = stderr.map { " (\($0))" } ?? ""
            return "Container exited with code \(exitCode)\(detail)"
        }
    }
}

/// Contract for running isolated containers.
///
/// `ContainerWorker` talks to this protocol. The production implementation
/// (`ContainerizationRuntime`) uses Apple's Containerization stack on
/// macOS 26. Tests inject a `MockContainerRuntime`.
protocol ContainerRuntime: Sendable {
    /// Whether the runtime is available on this system.
    var isAvailable: Bool { get async }

    /// Pre-warm the runtime (e.g. validate image, prepare caches).
    func prepare(configuration: ContainerConfiguration) async throws

    /// Create and start a container. Returns a handle for tracking.
    func start(configuration: ContainerConfiguration) async throws -> ContainerHandle

    /// Wait for the container to exit normally. Returns exit status.
    func waitForExit(handle: ContainerHandle) async throws -> ContainerExitStatus

    /// Graceful shutdown.
    func stop(handle: ContainerHandle) async throws

    /// Forced termination (for timeout / cancellation).
    func kill(handle: ContainerHandle) async throws
}
