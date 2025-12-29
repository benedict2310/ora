//
//  ParakeetModelDownloader.swift
//  Ora
//
//  Model availability checking and download state for Parakeet ASR
//

import Foundation
import os
import CryptoKit

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
        case checksumMismatch(file: String, expected: String, actual: String)
        case modelCorrupted(name: String)

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
            case .checksumMismatch(let file, let expected, let actual):
                return "Checksum mismatch for \(file): expected \(expected.prefix(8))..., got \(actual.prefix(8))..."
            case .modelCorrupted(let name):
                return "Model file appears corrupted: \(name)"
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

    // MARK: - Known Checksums

    /// Known SHA256 checksums for Parakeet v3 model files
    /// Note: CoreML model packages (.mlmodelc) are directories, not single files,
    /// so we only track checksums for regular files like vocabulary.txt
    private static let knownChecksums: [String: String] = [:]
    // Add known checksums here as they become available
    // e.g., "vocabulary.txt": "abc123..."

    /// Verify that all required model files exist and are valid
    /// - Throws: DownloadError.modelFileMissing if a required file is missing,
    ///           DownloadError.modelCorrupted if a file appears corrupted,
    ///           DownloadError.checksumMismatch if checksum verification fails
    func verifyModelsExist() throws {
        let repoPath = Self.repoDirectory
        let requiredFiles = ModelIdentifier.parakeetTDT.requiredFiles
        let fm = FileManager.default

        for file in requiredFiles {
            let path = repoPath.appendingPathComponent(file)

            // Check existence
            guard fm.fileExists(atPath: path.path) else {
                throw DownloadError.modelFileMissing(name: file)
            }

            // Check file/directory is non-empty (basic corruption check)
            if file.hasSuffix(".mlmodelc") {
                // CoreML model packages are directories
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    throw DownloadError.modelCorrupted(name: file)
                }
                // Check directory has contents
                let contents = try? fm.contentsOfDirectory(atPath: path.path)
                guard let contents, !contents.isEmpty else {
                    throw DownloadError.modelCorrupted(name: file)
                }
            } else {
                // Regular files - check non-zero size and compute SHA256
                let attrs = try? fm.attributesOfItem(atPath: path.path)
                let size = attrs?[.size] as? Int64 ?? 0
                guard size > 0 else {
                    throw DownloadError.modelCorrupted(name: file)
                }

                // Compute and verify SHA256 for regular files
                try verifyFileChecksum(at: path, fileName: file)
            }
        }

        logger.debug("Model verification passed for \(requiredFiles.count) files")
    }

    /// Verify checksum for a regular file
    private func verifyFileChecksum(at path: URL, fileName: String) throws {
        do {
            let computedHash = try computeSHA256(at: path)
            logger.debug("SHA256 for \(fileName): \(computedHash)")

            // If we have a known checksum, verify it
            if let expectedHash = Self.knownChecksums[fileName] {
                guard computedHash.lowercased() == expectedHash.lowercased() else {
                    throw DownloadError.checksumMismatch(
                        file: fileName,
                        expected: expectedHash,
                        actual: computedHash
                    )
                }
                logger.debug("Checksum verified for \(fileName)")
            }
        } catch let error as DownloadError {
            throw error
        } catch {
            // File read error during checksum - treat as corruption
            logger.warning("Failed to compute SHA256 for \(fileName): \(error.localizedDescription)")
            throw DownloadError.modelCorrupted(name: fileName)
        }
    }

    /// Verify a file against an expected SHA256 checksum
    /// - Parameters:
    ///   - filePath: Path to the file to verify
    ///   - expectedHash: Expected SHA256 hash (hex string, lowercase)
    /// - Throws: DownloadError.checksumMismatch if hashes don't match
    func verifyChecksum(at filePath: URL, expectedHash: String) throws {
        let actualHash = try computeSHA256(at: filePath)
        guard actualHash.lowercased() == expectedHash.lowercased() else {
            throw DownloadError.checksumMismatch(
                file: filePath.lastPathComponent,
                expected: expectedHash,
                actual: actualHash
            )
        }
    }

    /// Compute SHA256 hash of a file
    /// - Parameter filePath: Path to the file
    /// - Returns: Hex-encoded SHA256 hash string (lowercase)
    func computeSHA256(at filePath: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: filePath)
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB chunks

        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
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
