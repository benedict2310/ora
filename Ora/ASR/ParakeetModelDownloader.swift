//
//  ParakeetModelDownloader.swift
//  Ora
//
//  Model availability checking and download state for Parakeet ASR
//

import Foundation
import os

final class ParakeetModelDownloader: @unchecked Sendable {

    // MARK: - State

    enum State: Equatable, Sendable {
        case idle
        case running(progress: Double, fileIndex: Int, fileCount: Int, currentFile: String?)
        case verifying
        case done(URL)
        case failed(Error)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.running(let p1, let i1, let c1, let f1), .running(let p2, let i2, let c2, let f2)):
                return p1 == p2 && i1 == i2 && c1 == c2 && f1 == f2
            case (.verifying, .verifying): return true
            case (.done(let u1), .done(let u2)): return u1 == u2
            case (.failed(let e1), .failed(let e2)):
                return e1.localizedDescription == e2.localizedDescription
            default: return false
            }
        }
    }

    // MARK: - Errors

    enum DownloadError: LocalizedError, Sendable {
        case invalidResponse
        case rateLimited(statusCode: Int)
        case noFilesFound
        case downloadFailed(path: String)
        case modelFileMissing(name: String)
        case networkUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from model registry."
            case .rateLimited(let status):
                return "Download rate limited (HTTP \(status)). Try again later."
            case .noFilesFound:
                return "No model files found in repository."
            case .downloadFailed(let path):
                return "Failed to download: \(path)"
            case .modelFileMissing(let name):
                return "Required model file missing: \(name)"
            case .networkUnavailable:
                return "Network connection unavailable."
            }
        }
    }

    // MARK: - Properties

    /// State change callback (called on MainActor)
    var onState: (@MainActor (State) -> Void)?

    private let logger = Logger(subsystem: "com.ora.asr", category: "ParakeetModelDownloader")

    // MARK: - Paths

    /// Repository directory for Parakeet models
    static var repoDirectory: URL {
        ModelPaths.path(for: .parakeetTDT)
    }

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Check if all required models are available locally
    func modelsAvailable() -> Bool {
        let repoPath = Self.repoDirectory
        let requiredFiles = ModelIdentifier.parakeetTDT.requiredFiles

        return requiredFiles.allSatisfy { fileName in
            let path = repoPath.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: path.path)
        }
    }

    /// Verify that all required model files exist
    /// - Throws: DownloadError.modelFileMissing if a required file is missing
    func verifyModelsExist() throws {
        let repoPath = Self.repoDirectory
        let requiredFiles = ModelIdentifier.parakeetTDT.requiredFiles

        for file in requiredFiles {
            let path = repoPath.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw DownloadError.modelFileMissing(name: file)
            }
        }
    }

    /// Get the total size of downloaded models
    func downloadedSize() -> Int64 {
        ModelPaths.directorySize(at: Self.repoDirectory)
    }

    // MARK: - State Management

    /// Update state and notify observers
    func notifyState(_ state: State) {
        Task { @MainActor in
            self.onState?(state)
        }
        NotificationCenter.default.post(
            name: .parakeetDownloadStateDidChange,
            object: state
        )
    }
}
