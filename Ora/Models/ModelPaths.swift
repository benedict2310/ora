//
//  ModelPaths.swift
//  Ora
//
//  File path utilities for model storage
//

import Foundation

enum ModelPaths {

    // MARK: - Base Directories

    /// Base application support directory
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// Ora's root directory
    static var oraRoot: URL {
        applicationSupport.appendingPathComponent("Ora", isDirectory: true)
    }

    /// Models directory
    static var modelsRoot: URL {
        oraRoot.appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Model Paths

    /// Get path for a specific model
    static func path(for model: ModelIdentifier) -> URL {
        modelsRoot.appendingPathComponent(model.storagePath, isDirectory: true)
    }

    /// Metadata file path
    static var metadataFile: URL {
        oraRoot.appendingPathComponent("model-metadata.json")
    }

    // MARK: - Directory Management

    /// Ensure all directories exist
    static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        for category in ModelCategory.allCases {
            let categoryPath = modelsRoot.appendingPathComponent(category.rawValue.lowercased(), isDirectory: true)
            try fm.createDirectory(at: categoryPath, withIntermediateDirectories: true)
        }
    }

    /// Check if model directory exists
    /// - Warning: This only checks if the directory exists, not if all required files are present.
    ///   Use `DefaultModelDownloader.shared.exists(model:at:)` for thorough validation.
    @available(*, deprecated, message: "Use DefaultModelDownloader.shared.exists(model:at:) for thorough validation")
    static func modelExists(_ model: ModelIdentifier) -> Bool {
        let path = self.path(for: model)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Calculate size of a directory
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Remove model directory
    static func removeModel(_ model: ModelIdentifier) throws {
        let path = self.path(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}
