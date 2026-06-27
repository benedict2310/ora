//
//  ContainerImageManager.swift
//  Ora
//
//  Locate and validate the bundled container image and runtime assets
//  shipped inside the app.
//

import Foundation
import os

/// Manages the container image and runtime assets that ship inside the
/// signed app bundle.
///
/// The Containerization framework requires:
/// 1. A Linux kernel (`vmlinux`)
/// 2. An initfs image (the lightweight init system)
/// 3. An OCI container image (the research agent rootfs)
///
/// No runtime download path — all assets must be present in the bundle
/// at build time. This is a deliberate product/security choice.
struct ContainerImageManager: Sendable {

    // MARK: - Constants

    /// OCI image bundle resource name (contains the rootfs with Python + agent).
    static let imageBundleResourceName = "research-container"
    static let imageBundleResourceExtension = "img"

    /// Linux kernel for the VM that hosts the container.
    static let kernelBundleResourceName = "vmlinux"
    static let kernelBundleResourceExtension = "bin"

    /// Init filesystem (vminitd) - the lightweight init process.
    static let initfsBundleResourceName = "initfs"
    static let initfsBundleResourceExtension = "ext4"

    // MARK: - Properties

    private let bundle: Bundle
    private let logger = Logger.ora(category: "container")

    // MARK: - Init

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Public

    /// Whether all required container runtime assets are present in the app bundle.
    var isImageAvailable: Bool {
        return self.imageURL != nil && self.kernelURL != nil && self.initfsURL != nil
    }

    /// URL of the bundled OCI container image, or `nil` if not found.
    var imageURL: URL? {
        return self.bundle.url(
            forResource: Self.imageBundleResourceName,
            withExtension: Self.imageBundleResourceExtension
        )
    }

    /// URL of the bundled Linux kernel, or `nil` if not found.
    var kernelURL: URL? {
        return self.bundle.url(
            forResource: Self.kernelBundleResourceName,
            withExtension: Self.kernelBundleResourceExtension
        )
    }

    /// URL of the bundled initfs image, or `nil` if not found.
    var initfsURL: URL? {
        return self.bundle.url(
            forResource: Self.initfsBundleResourceName,
            withExtension: Self.initfsBundleResourceExtension
        )
    }

    /// Validate that all bundled assets exist and pass basic integrity checks.
    func validate() throws {
        guard let imageURL = self.imageURL else {
            throw ContainerRuntimeError.imageNotFound(
                path: "\(Self.imageBundleResourceName).\(Self.imageBundleResourceExtension)"
            )
        }
        try self.validateFile(at: imageURL, label: "Container image")

        guard let kernelURL = self.kernelURL else {
            throw ContainerRuntimeError.imageNotFound(
                path: "\(Self.kernelBundleResourceName).\(Self.kernelBundleResourceExtension)"
            )
        }
        try self.validateFile(at: kernelURL, label: "Linux kernel")

        guard let initfsURL = self.initfsURL else {
            throw ContainerRuntimeError.imageNotFound(
                path: "\(Self.initfsBundleResourceName).\(Self.initfsBundleResourceExtension)"
            )
        }
        try self.validateFile(at: initfsURL, label: "initfs")

        self.logger.info("All container runtime assets validated")
    }

    // MARK: - Private

    private func validateFile(at url: URL, label: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int64, fileSize > 0 else {
            throw ContainerRuntimeError.imageValidationFailed(
                reason: "\(label) file is empty: \(url.lastPathComponent)"
            )
        }
        self.logger.info("\(label) validated: \(url.lastPathComponent) (\(fileSize) bytes)")
    }
}
