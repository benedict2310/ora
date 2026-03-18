//
//  ContainerImageManager.swift
//  Ora
//
//  Locate and validate the bundled container image shipped inside the app.
//

import Foundation
import os

/// Manages the container image that ships inside the signed app bundle.
///
/// No runtime download path — the image/assets must be present in the
/// bundle at build time. This is a deliberate product/security choice.
struct ContainerImageManager: Sendable {

    // MARK: - Constants

    static let imageBundleResourceName = "research-container"
    static let imageBundleResourceExtension = "img"

    // MARK: - Properties

    private let bundle: Bundle
    private let logger = Logger.ora(category: "container")

    // MARK: - Init

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Public

    /// Whether the container image is present in the app bundle.
    var isImageAvailable: Bool {
        return self.imageURL != nil
    }

    /// URL of the bundled container image, or `nil` if not found.
    var imageURL: URL? {
        return self.bundle.url(
            forResource: Self.imageBundleResourceName,
            withExtension: Self.imageBundleResourceExtension
        )
    }

    /// Validate the bundled image exists and passes basic integrity checks.
    func validate() throws {
        guard let url = self.imageURL else {
            throw ContainerRuntimeError.imageNotFound(
                path: "\(Self.imageBundleResourceName).\(Self.imageBundleResourceExtension)"
            )
        }

        // Verify the file is readable and non-empty
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int64, fileSize > 0 else {
            throw ContainerRuntimeError.imageValidationFailed(
                reason: "Container image file is empty."
            )
        }

        self.logger.info("Container image validated: \(url.lastPathComponent) (\(fileSize) bytes)")
    }
}
