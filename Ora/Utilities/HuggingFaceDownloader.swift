//
//  HuggingFaceDownloader.swift
//  Ora
//
//  Resumable file downloader for HuggingFace model files
//

import Foundation
import os

// MARK: - FileDownloader Protocol

/// Protocol for downloading files with progress reporting
protocol FileDownloader: Sendable {
    /// Download a file from URL to destination with progress reporting
    func download(
        url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

// MARK: - HuggingFaceDownloader

/// Downloads files from HuggingFace with resume support and progress reporting
final class HuggingFaceDownloader: NSObject, FileDownloader, @unchecked Sendable {

    // MARK: - Types

    enum DownloadError: LocalizedError, Sendable {
        case invalidURL(String)
        case httpError(statusCode: Int)
        case fileSystemError(String)
        case noData
        case cancelled
        case resumeNotSupported
        case incompleteDownload(expected: Int64, actual: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid URL: \(url)"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .fileSystemError(let reason):
                return "File system error: \(reason)"
            case .noData:
                return "No data received"
            case .cancelled:
                return "Download cancelled"
            case .resumeNotSupported:
                return "Server does not support resume"
            case .incompleteDownload(let expected, let actual):
                return "Download incomplete: expected \(expected) bytes, received \(actual) bytes"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "HuggingFaceDownloader")
    private let urlSession: URLSession

    // MARK: - State for delegate callbacks

    private struct DownloadState {
        var progressHandler: (@Sendable (Double) -> Void)?
        var completion: CheckedContinuation<Void, Error>?
        var destinationURL: URL?
        var existingBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var fileHandle: FileHandle?
    }

    private let stateLock = NSLock()
    private var downloadState: DownloadState?

    // MARK: - Initialization

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 // 1 hour for large files
        config.waitsForConnectivity = true

        // Use a temporary placeholder session, will be replaced
        self.urlSession = URLSession(configuration: config)
        super.init()
    }

    /// Create with custom URLSession (for testing)
    init(urlSession: URLSession) {
        self.urlSession = urlSession
        super.init()
    }

    // MARK: - FileDownloader

    func download(
        url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        self.logger.info("Starting download: \(url.lastPathComponent, privacy: .public) -> \(destination.path, privacy: .public)")

        // Create parent directory if needed
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Check for existing partial download
        let existingBytes = self.existingFileSize(at: destination)

        // Build request with range header for resume
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            self.logger.info("Resuming from byte \(existingBytes)")
        }

        // Perform download with data task for progress tracking
        do {
            try await self.performDownload(
                request: request,
                destination: destination,
                existingBytes: existingBytes,
                progress: progress
            )
        } catch {
            self.logger.error("Download failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Private

    private func existingFileSize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return attrs[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }

    private func performDownload(
        request: URLRequest,
        destination: URL,
        existingBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Use a temporary file for downloads to avoid deleting the original until we're sure
        // the new download is complete. This prevents data loss if download is interrupted.
        // BUG.04 FIX: Atomic downloads to prevent file deletion on interrupted downloads
        let tempDestination = destination.appendingPathExtension("tmp")
        
        // Check for existing partial download in temp file
        let tempExistingBytes = self.existingFileSize(at: tempDestination)
        
        // Use temp file's existing bytes for resume logic (not the destination file)
        let resumeBytes = tempExistingBytes
        
        // Build request with range header for resume from temp file
        var resumeRequest = request
        if resumeBytes > 0 {
            resumeRequest.setValue("bytes=\(resumeBytes)-", forHTTPHeaderField: "Range")
            self.logger.info("Resuming from byte \(resumeBytes) (temp file)")
        }
        
        // Use bytes async sequence for streaming download with progress
        let (asyncBytes, response) = try await self.urlSession.bytes(for: resumeRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.httpError(statusCode: 0)
        }

        // Special handling for 416 (Range Not Satisfiable)
        // This happens if we have the full file already and requested a range past the end
        if httpResponse.statusCode == 416 && resumeBytes > 0 {
            self.logger.warning("Received 416 Range Not Satisfiable. Temp file may be complete at \(resumeBytes) bytes.")
            // Atomically move temp file to destination
            try self.atomicMove(from: tempDestination, to: destination)
            progress(1.0)
            return
        }

        // Handle response codes
        // 200 = full file, 206 = partial content (resume)
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            throw DownloadError.httpError(statusCode: httpResponse.statusCode)
        }

        // Determine if we're resuming or starting fresh
        let isResuming = httpResponse.statusCode == 206
        let contentLength = httpResponse.expectedContentLength

        // Calculate total bytes for progress
        let totalBytes: Int64
        if isResuming {
            totalBytes = resumeBytes + (contentLength > 0 ? contentLength : 0)
        } else {
            totalBytes = contentLength > 0 ? contentLength : 0
            // If server returned 200 (not 206), we need to start fresh - remove temp file only
            // NEVER delete the destination file - it contains valid data we don't want to lose
            if resumeBytes > 0 && !isResuming {
                try? FileManager.default.removeItem(at: tempDestination)
            }
        }

        self.logger.debug("Response: \(httpResponse.statusCode), content-length: \(contentLength), total: \(totalBytes)")

        // Prepare temp file for writing (NOT the destination)
        let startBytes: Int64 = isResuming ? resumeBytes : 0
        try self.prepareFileForWriting(at: tempDestination, isResuming: isResuming)

        guard let fileHandle = try? FileHandle(forWritingTo: tempDestination) else {
            throw DownloadError.fileSystemError("Cannot open temp file for writing: \(tempDestination.path)")
        }

        defer {
            try? fileHandle.close()
        }

        // Seek to end if resuming
        if isResuming {
            try fileHandle.seekToEnd()
        }

        // Stream bytes to file with progress updates
        var bytesWritten: Int64 = startBytes
        let bufferSize = 64 * 1024 // 64KB buffer
        var buffer = Data(capacity: bufferSize)
        var lastProgressUpdate = Date()
        let progressUpdateInterval: TimeInterval = 0.1 // 100ms

        for try await byte in asyncBytes {
            buffer.append(byte)

            // Write buffer when full
            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                bytesWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                // Throttled progress update
                let now = Date()
                if now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
                    if totalBytes > 0 {
                        let prog = Double(bytesWritten) / Double(totalBytes)
                        progress(min(prog, 1.0))
                    }
                    lastProgressUpdate = now
                }
            }
        }

        // Write remaining bytes
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
            bytesWritten += Int64(buffer.count)
        }

        // Verify download was complete
        // If we expected a specific number of bytes (Content-Length header), verify we got them all
        if totalBytes > 0 && bytesWritten < totalBytes {
            self.logger.error("Download incomplete: expected \(totalBytes) bytes, got \(bytesWritten) bytes")
            // Clean up the partial TEMP file (never delete destination - it has valid data)
            try? FileManager.default.removeItem(at: tempDestination)
            throw DownloadError.incompleteDownload(expected: totalBytes, actual: bytesWritten)
        }

        // Atomically move temp file to destination
        // This is the key fix for BUG.04 - we only replace the destination after successful download
        try self.atomicMove(from: tempDestination, to: destination)

        // Final progress
        progress(1.0)

        self.logger.info("Download complete: \(bytesWritten) bytes written to \(destination.lastPathComponent, privacy: .public)")
    }

    private func prepareFileForWriting(at url: URL, isResuming: Bool) throws {
        let fm = FileManager.default

        if isResuming {
            // File should exist, just verify
            guard fm.fileExists(atPath: url.path) else {
                throw DownloadError.fileSystemError("Expected file to exist for resume: \(url.path)")
            }
        } else {
            // Create new file
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw DownloadError.fileSystemError("Cannot create file: \(url.path)")
            }
        }
    }
    
    /// Atomically move a file from source to destination, replacing destination if it exists
    /// This ensures the destination is never in a partial/corrupted state
    private func atomicMove(from source: URL, to destination: URL) throws {
        let fm = FileManager.default

        // Verify source file exists before attempting move
        guard fm.fileExists(atPath: source.path) else {
            self.logger.error("Cannot atomicMove: source file does not exist: \(source.path)")
            throw DownloadError.fileSystemError("Source file does not exist: \(source.path)")
        }

        // Use replaceItemAt for truly atomic replacement if destination exists
        // This is the only way to guarantee atomicity on macOS/iOS
        if fm.fileExists(atPath: destination.path) {
            // Create a backup URL in case replaceItemAt fails
            let backupURL = destination.appendingPathExtension("backup")

            do {
                // First, try the atomic replace
                _ = try fm.replaceItemAt(destination, withItemAt: source, backupItemName: nil, options: [])
                self.logger.debug("Atomically replaced \(destination.lastPathComponent)")
            } catch {
                // replaceItemAt failed - fall back to manual but safer approach:
                // 1. Move destination to backup
                // 2. Move source to destination
                // 3. Delete backup (or restore on failure)
                self.logger.warning("replaceItemAt failed, using fallback: \(error.localizedDescription)")

                // Move existing file to backup
                if fm.fileExists(atPath: backupURL.path) {
                    try? fm.removeItem(at: backupURL)
                }
                try fm.moveItem(at: destination, to: backupURL)

                do {
                    // Move source to destination
                    try fm.moveItem(at: source, to: destination)
                    // Success - remove backup
                    try? fm.removeItem(at: backupURL)
                    self.logger.debug("Fallback move succeeded for \(destination.lastPathComponent)")
                } catch {
                    // Move failed - restore backup
                    try? fm.moveItem(at: backupURL, to: destination)
                    throw error
                }
            }
        } else {
            // No existing file - simple move
            try fm.moveItem(at: source, to: destination)
            self.logger.debug("Moved \(source.lastPathComponent) to \(destination.lastPathComponent)")
        }
    }
}

// MARK: - HuggingFace URL Builder

extension HuggingFaceDownloader {

    /// Build URL for a file in a HuggingFace repository
    /// Format: https://huggingface.co/{repo}/resolve/main/{path}
    static func fileURL(repo: String, path: String, revision: String = "main") -> URL? {
        let urlString = "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)"
        return URL(string: urlString)
    }

    /// Fetch the list of files in a HuggingFace repository
    static func listFiles(repo: String, revision: String = "main") async throws -> [String] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)") else {
            throw DownloadError.invalidURL("Invalid repo: \(repo)")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.httpError(statusCode: status)
        }

        // Parse JSON array of file objects
        struct FileInfo: Decodable {
            let path: String
            let type: String // "file" or "directory"
        }

        let files = try JSONDecoder().decode([FileInfo].self, from: data)
        return files.filter { $0.type == "file" }.map { $0.path }
    }
}

// MARK: - MockFileDownloader for Testing

/// Mock file downloader for testing
final class MockFileDownloader: FileDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldSucceed = true
    private var _downloadDelay: TimeInterval = 0.1
    private var _downloadedFiles: [URL] = []
    private var _fileSizeOverrides: [String: Int64] = [:]

    var shouldSucceed: Bool {
        get { lock.withLock { _shouldSucceed } }
        set { lock.withLock { _shouldSucceed = newValue } }
    }

    var downloadDelay: TimeInterval {
        get { lock.withLock { _downloadDelay } }
        set { lock.withLock { _downloadDelay = newValue } }
    }

    var downloadedFiles: [URL] {
        lock.withLock { _downloadedFiles }
    }

    var fileSizeOverrides: [String: Int64] {
        get { lock.withLock { _fileSizeOverrides } }
        set { lock.withLock { _fileSizeOverrides = newValue } }
    }

    func download(
        url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard self.shouldSucceed else {
            throw HuggingFaceDownloader.DownloadError.httpError(statusCode: 500)
        }

        // Simulate download with progress
        for i in 1...10 {
            try await Task.sleep(for: .milliseconds(Int(self.downloadDelay * 100)))
            progress(Double(i) / 10.0)
        }

        // Create the file
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let sizeOverride = lock.withLock { () -> Int64? in
            if let override = _fileSizeOverrides[destination.lastPathComponent] {
                return override
            }

            let path = destination.path
            for (key, value) in _fileSizeOverrides where path.hasSuffix("/" + key) {
                return value
            }

            return nil
        }
        try self.writeMockFile(to: destination, sizeOverride: sizeOverride)

        lock.withLock {
            _downloadedFiles.append(destination)
        }
    }

    func reset() {
        lock.withLock {
            _downloadedFiles = []
        }
    }

    private func writeMockFile(to destination: URL, sizeOverride: Int64?) throws {
        if let sizeOverride = sizeOverride {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw HuggingFaceDownloader.DownloadError.fileSystemError("Cannot create file: \(destination.path)")
            }
            let fileHandle = try FileHandle(forWritingTo: destination)
            try fileHandle.truncate(atOffset: UInt64(max(0, sizeOverride)))
            try fileHandle.close()
        } else {
            try Data("mock content".utf8).write(to: destination)
        }
    }
}
