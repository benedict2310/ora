//
//  ContainerizationRuntime.swift
//  Ora
//
//  Production implementation of ContainerRuntime backed by Apple's
//  Containerization package (https://github.com/apple/containerization)
//  on macOS 26.
//

import Containerization
import ContainerizationOCI
import Foundation
import os

/// Production container runtime using Apple's Containerization package on macOS 26+.
///
/// Each task gets a fresh `LinuxContainer` instance. No state carries between tasks.
/// The container has public internet access but no access to host filesystem,
/// local network, or credentials.
@available(macOS 26, *)
final class ContainerizationRuntime: ContainerRuntime, @unchecked Sendable {

    // MARK: - Types

    /// Tracks a running container and its manager so we can stop/kill/cleanup.
    private struct ActiveContainer {
        var container: LinuxContainer
        var manager: ContainerManager
        let stateDirectory: URL
    }

    // MARK: - Properties

    private let logger = Logger.ora(category: "container")
    private let imageManager: ContainerImageManager

    /// Root directory for container state (image store, rootfs layers).
    private let stateRoot: URL

    /// Active containers keyed by handle ID.
    private let activeContainers = OSAllocatedUnfairLock<[String: ActiveContainer]>(initialState: [:])

    // MARK: - Init

    init(
        imageManager: ContainerImageManager = ContainerImageManager(),
        stateRoot: URL? = nil
    ) {
        self.imageManager = imageManager
        self.stateRoot = stateRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("ContainerState", isDirectory: true)
    }

    // MARK: - ContainerRuntime

    var isAvailable: Bool {
        get async {
            // All three assets must be bundled: kernel, initfs, OCI image
            return self.imageManager.isImageAvailable
        }
    }

    func prepare(configuration: ContainerConfiguration) async throws {
        guard self.imageManager.isImageAvailable else {
            throw ContainerRuntimeError.imageNotFound(path: configuration.imagePath.path)
        }

        // Ensure state root exists
        try FileManager.default.createDirectory(
            at: self.stateRoot,
            withIntermediateDirectories: true
        )

        self.logger.info("Container runtime prepared (state root: \(self.stateRoot.path))")
    }

    func start(configuration: ContainerConfiguration) async throws -> ContainerHandle {
        guard self.imageManager.isImageAvailable else {
            throw ContainerRuntimeError.imageNotFound(path: configuration.imagePath.path)
        }

        let containerID = UUID().uuidString
        let fm = FileManager.default

        // Ensure shared directory exists
        if !fm.fileExists(atPath: configuration.sharedDirectoryPath.path) {
            try fm.createDirectory(
                at: configuration.sharedDirectoryPath,
                withIntermediateDirectories: true
            )
        }

        do {
            // Load the kernel from bundled assets
            guard let kernelURL = self.imageManager.kernelURL else {
                throw ContainerRuntimeError.startFailed(reason: "Linux kernel not found in bundle")
            }

            let kernel = Kernel(
                path: kernelURL,
                platform: .linuxArm
            )

            // Load the initfs from bundled assets
            guard let initfsURL = self.imageManager.initfsURL else {
                throw ContainerRuntimeError.startFailed(reason: "initfs not found in bundle")
            }
            let initfs = Mount.block(
                format: "ext4",
                source: initfsURL.path,
                destination: "/",
                options: ["ro"]
            )

            // Create an image store in the state root for this container
            let containerStateDir = self.stateRoot.appendingPathComponent(containerID, isDirectory: true)
            try fm.createDirectory(at: containerStateDir, withIntermediateDirectories: true)

            let imageStore = try ImageStore(path: containerStateDir)

            // Create container manager with NAT networking for internet access
            var network: VmnetNetwork? = nil
            if configuration.networkPolicy != .noNetwork {
                network = try VmnetNetwork()
            }

            var manager = try ContainerManager(
                kernel: kernel,
                initfs: initfs,
                imageStore: imageStore,
                network: network
            )

            // Create the container from the bundled OCI image
            let imageReference = configuration.imagePath.path

            // Mount for the shared directory (virtiofs share)
            let sharedMount = Mount.share(
                source: configuration.sharedDirectoryPath.path,
                destination: "/task"
            )

            let container = try await manager.create(
                containerID,
                reference: imageReference,
                rootfsSizeInBytes: 2 * 1024 * 1024 * 1024,  // 2 GiB rootfs
                readOnly: false,
                configuration: { (config: inout LinuxContainer.Configuration) in
                    // Process configuration
                    config.process.arguments = ["python3", "/agent/agent.py"]
                    config.process.workingDirectory = "/task"

                    // Resource limits
                    config.cpus = configuration.cpuCount
                    config.memoryInBytes = UInt64(configuration.memoryLimitMB) * 1024 * 1024

                    // Mount shared directory as /task inside the container
                    config.mounts.append(sharedMount)

                    // DNS for internet access
                    if configuration.networkPolicy != .noNetwork {
                        config.dns = DNS()
                    }
                }
            )

            // Start the container
            try await container.create()
            try await container.start()

            // Track the active container
            let active = ActiveContainer(
                container: container,
                manager: manager,
                stateDirectory: containerStateDir
            )
            self.activeContainers.withLock { $0[containerID] = active }

            self.logger.info("Container \(containerID) started (cpus: \(configuration.cpuCount), memory: \(configuration.memoryLimitMB)MB)")

            return ContainerHandle(
                id: containerID,
                sharedDirectoryURL: configuration.sharedDirectoryPath
            )

        } catch let error as ContainerRuntimeError {
            throw error
        } catch {
            throw ContainerRuntimeError.startFailed(reason: error.localizedDescription)
        }
    }

    func waitForExit(handle: ContainerHandle) async throws -> ContainerExitStatus {
        guard let active = self.activeContainers.withLock({ $0[handle.id] }) else {
            throw ContainerRuntimeError.startFailed(reason: "No active container with id \(handle.id)")
        }

        self.logger.info("Waiting for container \(handle.id) to exit")

        let exitStatus = try await active.container.wait()

        self.logger.info("Container \(handle.id) exited with code \(exitStatus.exitCode)")

        return ContainerExitStatus(exitCode: exitStatus.exitCode, stderr: nil)
    }

    func stop(handle: ContainerHandle) async throws {
        guard let active = self.activeContainers.withLock({ $0[handle.id] }) else {
            return
        }

        self.logger.info("Stopping container \(handle.id)")

        try await active.container.stop()
        self.cleanupContainer(id: handle.id)
    }

    func kill(handle: ContainerHandle) async throws {
        guard let active = self.activeContainers.withLock({ $0[handle.id] }) else {
            return
        }

        self.logger.info("Killing container \(handle.id)")

        try await active.container.kill(.kill)
        self.cleanupContainer(id: handle.id)
    }

    // MARK: - Private

    private func cleanupContainer(id: String) {
        guard let active = self.activeContainers.withLock({ $0.removeValue(forKey: id) }) else {
            return
        }

        var manager = active.manager
        do {
            try manager.releaseNetwork(id)
        } catch {
            self.logger.debug("Failed to release container network: \(error.localizedDescription)")
        }
        do {
            try manager.delete(id)
        } catch {
            self.logger.debug("Failed to delete container state: \(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: active.stateDirectory)
    }
}
