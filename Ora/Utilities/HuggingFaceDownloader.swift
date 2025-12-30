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
        self.logger.info("Starting download: \(url.lastPathComponent) -> \(destination.path)")

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
        try await self.performDownload(
            request: request,
            destination: destination,
            existingBytes: existingBytes,
            progress: progress
        )
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
        // Use bytes async sequence for streaming download with progress
        let (asyncBytes, response) = try await self.urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.httpError(statusCode: 0)
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
            totalBytes = existingBytes + (contentLength > 0 ? contentLength : 0)
        } else {
            totalBytes = contentLength > 0 ? contentLength : 0
            // If server returned 200 (not 206), we need to start fresh
            if existingBytes > 0 && !isResuming {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        self.logger.debug("Response: \(httpResponse.statusCode), content-length: \(contentLength), total: \(totalBytes)")

        // Prepare file for writing
        let startBytes: Int64 = isResuming ? existingBytes : 0
        try self.prepareFileForWriting(at: destination, isResuming: isResuming)

        guard let fileHandle = try? FileHandle(forWritingTo: destination) else {
            throw DownloadError.fileSystemError("Cannot open file for writing: \(destination.path)")
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

        // Final progress
        progress(1.0)

        self.logger.info("Download complete: \(bytesWritten) bytes written to \(destination.lastPathComponent)")
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
        try Data("mock content".utf8).write(to: destination)

        lock.withLock {
            _downloadedFiles.append(destination)
        }
    }

    func reset() {
        lock.withLock {
            _downloadedFiles = []
        }
    }
}
