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
        if let override = applicationSupportOverride {
            return override
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// Test-only override for application support root.
    /// Leave unset in production code.
    nonisolated(unsafe) static var applicationSupportOverride: URL?

    /// Ora's root directory
    static var oraRoot: URL {
        applicationSupport.appendingPathComponent("Ora", isDirectory: true)
    }

    /// User-authored skills directory
    static var skillsRoot: URL {
        oraRoot.appendingPathComponent("Skills", isDirectory: true)
    }

    /// Agent-authored skills directory
    static var agentSkillsRoot: URL {
        oraRoot.appendingPathComponent("AgentSkills", isDirectory: true)
    }

    /// Models directory
    static var modelsRoot: URL {
        oraRoot.appendingPathComponent("Models", isDirectory: true)
    }

    /// FluidAudio stores Parakeet models under its own Application Support root
    static var fluidAudioModelsRoot: URL {
        applicationSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    // MARK: - Model Paths

    /// Get path for a specific model
    static func path(for model: ModelIdentifier) -> URL {
        if model == .parakeetTDT {
            return fluidAudioModelsRoot.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        }
        return modelsRoot.appendingPathComponent(model.storagePath, isDirectory: true)
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
    /// - Warning: This deletes the ENTIRE model directory. Only call when you're sure
    ///   you want to remove all files for this model (e.g., user-initiated delete).
    static func removeModel(_ model: ModelIdentifier) throws {
        let path = self.path(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            // BUG.04 FIX: Log when model directories are deleted to help diagnose issues
            Self.logDiagnostic("MODEL DELETION: Removing entire directory for \(model.displayName) at \(path.path)")
            try FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Diagnostic Logging

    /// Log diagnostic messages to file for debugging model management issues
    private static func logDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let oraDir = appSupport.appendingPathComponent("Ora")
        let logFile = oraDir.appendingPathComponent("model-diagnostic.log")

        try? fm.createDirectory(at: oraDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            }
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}
