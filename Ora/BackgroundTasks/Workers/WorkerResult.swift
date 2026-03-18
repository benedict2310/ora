//
//  WorkerResult.swift
//  Ora
//
//  Codable worker outputs shared across background task stages.
//

import Foundation

struct WorkerResult: Codable, Sendable, Equatable {
    let pages: [PageResult]
    let metadata: WorkerMetadata
    let failedURLs: [FailedPage]
    let provenance: WorkerProvenance?

    init(
        pages: [PageResult],
        metadata: WorkerMetadata,
        failedURLs: [FailedPage],
        provenance: WorkerProvenance? = nil
    ) {
        self.pages = pages
        self.metadata = metadata
        self.failedURLs = failedURLs
        self.provenance = provenance
    }
}

/// Provenance data from research tasks (container-based or in-process web search).
struct WorkerProvenance: Codable, Sendable, Equatable {
    let query: String?
    let searchQueries: [String]
    let discoveryRationale: String?
    let domainsUsed: [String]
}

struct PageResult: Codable, Sendable, Equatable {
    let url: String
    let finalURL: String
    let title: String?
    let text: String
    let contentType: String
    let wordCount: Int
    let fetchedAt: Date
    let rawHTML: String?
}

struct WorkerMetadata: Codable, Sendable, Equatable {
    let taskID: UUID
    let taskKind: String
    let startedAt: Date
    let completedAt: Date
    let requestedURLCount: Int
    let succeededURLCount: Int
    let failedURLCount: Int
    let processedSequentially: Bool
}

enum WorkerFailureCode: String, Codable, Sendable, Equatable {
    case invalidURL
    case invalidResponse
    case unsupportedContentType
    case fetchFailed
    case extractionFailed
}

struct FailedPage: Codable, Sendable, Equatable {
    let url: String
    let finalURL: String?
    let code: WorkerFailureCode
    let message: String
    let statusCode: Int?
    let failedAt: Date
}
