//
//  ContainerNetworkPolicy.swift
//  Ora
//
//  Host-side network policy model for container isolation.
//

import Foundation

/// Network restrictions enforced by the host runtime on the container.
///
/// The container must only reach the public internet. RFC 1918/link-local
/// ranges and the host loopback are blocked by the runtime. This struct
/// models the intent; the `ContainerizationRuntime` translates it into
/// Containerization-stack configuration.
struct ContainerNetworkPolicy: Codable, Sendable, Equatable {

    // MARK: - Properties

    /// Allow outbound internet access (public IPs only).
    let allowPublicInternet: Bool

    /// Deny access to RFC 1918 / link-local ranges and the host loopback.
    let blockLocalNetwork: Bool

    /// Deny access to the host filesystem.
    let blockHostFilesystem: Bool

    // MARK: - Init

    init(
        allowPublicInternet: Bool = true,
        blockLocalNetwork: Bool = true,
        blockHostFilesystem: Bool = true
    ) {
        self.allowPublicInternet = allowPublicInternet
        self.blockLocalNetwork = blockLocalNetwork
        self.blockHostFilesystem = blockHostFilesystem
    }

    // MARK: - Convenience

    /// Fully isolated policy — the default for all research containers.
    static let isolated = ContainerNetworkPolicy(
        allowPublicInternet: true,
        blockLocalNetwork: true,
        blockHostFilesystem: true
    )

    /// No network at all (for testing).
    static let noNetwork = ContainerNetworkPolicy(
        allowPublicInternet: false,
        blockLocalNetwork: true,
        blockHostFilesystem: true
    )
}
