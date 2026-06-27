//
//  ContainerIO.swift
//  Ora
//
//  Serialize/deserialize input/output for container task execution.
//

import Foundation
import os

/// Errors from the container I/O layer.
enum ContainerIOError: LocalizedError, Equatable, Sendable {
    case inputSerializationFailed(reason: String)
    case outputNotFound
    case outputTooLarge(sizeBytes: Int64, limitBytes: Int64)
    case outputMalformed(reason: String)
    case outputMissingRequiredField(field: String)
    case unexpectedFilesInSharedDirectory(filenames: [String])
    case symlinkDetected(path: String)
    case containerStderrAvailable(stderr: String)

    var errorDescription: String? {
        switch self {
        case .inputSerializationFailed(let reason):
            return "Failed to write container input: \(reason)"
        case .outputNotFound:
            return "Container did not produce an output.json file."
        case .outputTooLarge(let sizeBytes, let limitBytes):
            return "Container output too large (\(sizeBytes) bytes, limit: \(limitBytes))."
        case .outputMalformed(let reason):
            return "Container output is malformed: \(reason)"
        case .outputMissingRequiredField(let field):
            return "Container output missing required field: \(field)"
        case .unexpectedFilesInSharedDirectory(let filenames):
            return "Unexpected files in container shared directory: \(filenames.joined(separator: ", "))"
        case .symlinkDetected(let path):
            return "Symlink detected in container shared directory: \(path)"
        case .containerStderrAvailable(let stderr):
            return "Container stderr: \(stderr)"
        }
    }
}

/// Container input JSON that gets written to the shared directory.
struct ContainerInput: Codable, Sendable, Equatable {
    let taskID: String
    let query: String?
    let urls: [String]
    let constraints: ContainerInputConstraints

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case query
        case urls
        case constraints
    }
}

struct ContainerInputConstraints: Codable, Sendable, Equatable {
    let maxSearchQueries: Int
    let maxPages: Int
    let maxDomains: Int
    let maxPageSizeBytes: Int
    let timeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case maxSearchQueries = "max_search_queries"
        case maxPages = "max_pages"
        case maxDomains = "max_domains"
        case maxPageSizeBytes = "max_page_size_bytes"
        case timeoutSeconds = "timeout_seconds"
    }

    static let `default` = ContainerInputConstraints(
        maxSearchQueries: 5,
        maxPages: 15,
        maxDomains: 8,
        maxPageSizeBytes: 5_242_880,
        timeoutSeconds: BackgroundTaskPolicy.defaultTimeoutSeconds
    )
}

/// Container output JSON read from the shared directory.
struct ContainerOutput: Codable, Sendable, Equatable {
    let taskID: String
    let status: String
    let query: String?
    let pages: [ContainerOutputPage]
    let metadata: ContainerOutputMetadata
    let failedURLs: [ContainerOutputFailedURL]?
    let provenance: ContainerOutputProvenance?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case query
        case pages
        case metadata
        case failedURLs = "failed_urls"
        case provenance
    }
}

struct ContainerOutputPage: Codable, Sendable, Equatable {
    let url: String
    let finalURL: String?
    let title: String?
    let text: String
    let contentType: String?
    let wordCount: Int?
    let fetchedAt: String?

    enum CodingKeys: String, CodingKey {
        case url
        case finalURL = "final_url"
        case title
        case text
        case contentType = "content_type"
        case wordCount = "word_count"
        case fetchedAt = "fetched_at"
    }
}

struct ContainerOutputMetadata: Codable, Sendable, Equatable {
    let startedAt: String?
    let completedAt: String?
    let searchQueriesUsed: [String]?
    let requestedURLCount: Int?
    let succeededURLCount: Int?
    let failedURLCount: Int?

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case searchQueriesUsed = "search_queries_used"
        case requestedURLCount = "requested_url_count"
        case succeededURLCount = "succeeded_url_count"
        case failedURLCount = "failed_url_count"
    }
}

struct ContainerOutputFailedURL: Codable, Sendable, Equatable {
    let url: String
    let code: String?
    let message: String?
}

struct ContainerOutputProvenance: Codable, Sendable, Equatable {
    let searchQueries: [String]?
    let discoveryRationale: String?
    let domainsUsed: [String]?

    enum CodingKeys: String, CodingKey {
        case searchQueries = "search_queries"
        case discoveryRationale = "discovery_rationale"
        case domainsUsed = "domains_used"
    }
}

// MARK: - ContainerIO

/// Handles reading and writing the container I/O files.
struct ContainerIO: Sendable {

    // MARK: - Constants

    static let inputFilename = "input.json"
    static let outputFilename = "output.json"
    static let maxOutputSizeBytes: Int64 = 10 * 1024 * 1024  // 10 MB
    static let allowedFilenames: Set<String> = ["input.json", "output.json"]

    private let logger = Logger.ora(category: "container")

    // MARK: - Write Input

    func writeInput(
        _ input: ContainerInput,
        to sharedDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(input)
        } catch {
            throw ContainerIOError.inputSerializationFailed(reason: error.localizedDescription)
        }

        let inputURL = sharedDirectory.appendingPathComponent(Self.inputFilename)
        try data.write(to: inputURL)
    }

    // MARK: - Read Output

    func readOutput(from sharedDirectory: URL) throws -> ContainerOutput {
        // Validate no unexpected files
        try self.validateSharedDirectoryContents(sharedDirectory)

        let outputURL = sharedDirectory.appendingPathComponent(Self.outputFilename)

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ContainerIOError.outputNotFound
        }

        // Check symlinks
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        if let fileType = attributes[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
            throw ContainerIOError.symlinkDetected(path: outputURL.path)
        }

        // Check size
        let fileSize = (attributes[.size] as? Int64) ?? 0
        guard fileSize <= Self.maxOutputSizeBytes else {
            throw ContainerIOError.outputTooLarge(
                sizeBytes: fileSize,
                limitBytes: Self.maxOutputSizeBytes
            )
        }

        let data = try Data(contentsOf: outputURL)

        let decoder = JSONDecoder()
        let output: ContainerOutput
        do {
            output = try decoder.decode(ContainerOutput.self, from: data)
        } catch {
            throw ContainerIOError.outputMalformed(reason: error.localizedDescription)
        }

        // Validate required fields
        guard !output.taskID.isEmpty else {
            throw ContainerIOError.outputMissingRequiredField(field: "task_id")
        }
        guard !output.status.isEmpty else {
            throw ContainerIOError.outputMissingRequiredField(field: "status")
        }

        return output
    }

    // MARK: - Map to WorkerResult

    func mapToWorkerResult(
        output: ContainerOutput,
        taskID: UUID,
        taskKind: String
    ) -> WorkerResult {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime]

        let pages: [PageResult] = output.pages.map { page in
            let fetchedAt = page.fetchedAt.flatMap { iso8601Formatter.date(from: $0) } ?? Date()
            return PageResult(
                url: page.url,
                finalURL: page.finalURL ?? page.url,
                title: page.title,
                text: page.text,
                contentType: page.contentType ?? "text/html",
                wordCount: page.wordCount ?? page.text.split(whereSeparator: \.isWhitespace).count,
                fetchedAt: fetchedAt,
                rawHTML: nil
            )
        }

        let failedURLs: [FailedPage] = (output.failedURLs ?? []).map { failed in
            FailedPage(
                url: failed.url,
                finalURL: nil,
                code: .fetchFailed,
                message: failed.message ?? "Unknown error",
                statusCode: nil,
                failedAt: Date()
            )
        }

        let startedAt = output.metadata.startedAt
            .flatMap { iso8601Formatter.date(from: $0) } ?? Date()
        let completedAt = output.metadata.completedAt
            .flatMap { iso8601Formatter.date(from: $0) } ?? Date()

        let metadata = WorkerMetadata(
            taskID: taskID,
            taskKind: taskKind,
            startedAt: startedAt,
            completedAt: completedAt,
            requestedURLCount: output.metadata.requestedURLCount ?? (pages.count + failedURLs.count),
            succeededURLCount: output.metadata.succeededURLCount ?? pages.count,
            failedURLCount: output.metadata.failedURLCount ?? failedURLs.count,
            processedSequentially: false
        )

        let provenance: WorkerProvenance?
        if let prov = output.provenance {
            provenance = WorkerProvenance(
                query: output.query,
                searchQueries: prov.searchQueries ?? [],
                discoveryRationale: prov.discoveryRationale,
                domainsUsed: prov.domainsUsed ?? []
            )
        } else if let query = output.query {
            provenance = WorkerProvenance(
                query: query,
                searchQueries: output.metadata.searchQueriesUsed ?? [],
                discoveryRationale: nil,
                domainsUsed: []
            )
        } else {
            provenance = nil
        }

        return WorkerResult(
            pages: pages,
            metadata: metadata,
            failedURLs: failedURLs,
            provenance: provenance
        )
    }

    // MARK: - Cleanup

    func cleanupSharedDirectory(_ directoryURL: URL) {
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            self.logger.warning("Failed to clean up container shared directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Validation

    private func validateSharedDirectoryContents(_ directoryURL: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)

        // Check for symlinks, device nodes, or other unexpected filesystem objects
        for filename in contents {
            let filePath = directoryURL.appendingPathComponent(filename).path
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            if let fileType = attributes[.type] as? FileAttributeType,
               fileType == .typeSymbolicLink {
                throw ContainerIOError.symlinkDetected(path: filePath)
            }
        }

        let unexpected = contents.filter { !Self.allowedFilenames.contains($0) }
        guard unexpected.isEmpty else {
            throw ContainerIOError.unexpectedFilesInSharedDirectory(filenames: unexpected)
        }
    }
}
