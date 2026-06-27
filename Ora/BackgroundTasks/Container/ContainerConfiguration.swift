//
//  ContainerConfiguration.swift
//  Ora
//
//  Codable container configuration for isolated task execution.
//

import Foundation

struct ContainerConfiguration: Codable, Sendable, Equatable {

    // MARK: - Defaults

    static let defaultMemoryLimitMB = 512
    static let defaultCPUCount = 2
    static let defaultTimeoutSeconds = BackgroundTaskPolicy.defaultTimeoutSeconds

    // MARK: - Properties

    let imagePath: URL
    let memoryLimitMB: Int
    let cpuCount: Int
    let networkPolicy: ContainerNetworkPolicy
    let sharedDirectoryPath: URL
    let timeoutSeconds: Int

    // MARK: - Init

    init(
        imagePath: URL,
        memoryLimitMB: Int = ContainerConfiguration.defaultMemoryLimitMB,
        cpuCount: Int = ContainerConfiguration.defaultCPUCount,
        networkPolicy: ContainerNetworkPolicy = ContainerNetworkPolicy(),
        sharedDirectoryPath: URL,
        timeoutSeconds: Int = ContainerConfiguration.defaultTimeoutSeconds
    ) {
        self.imagePath = imagePath
        self.memoryLimitMB = max(128, memoryLimitMB)
        self.cpuCount = max(1, cpuCount)
        self.networkPolicy = networkPolicy
        self.sharedDirectoryPath = sharedDirectoryPath
        self.timeoutSeconds = min(max(1, timeoutSeconds), BackgroundTaskPolicy.maximumTimeoutSeconds)
    }
}
