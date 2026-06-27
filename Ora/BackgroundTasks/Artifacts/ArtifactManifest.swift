//
//  ArtifactManifest.swift
//  Ora
//
//  Codable artifact metadata and persisted worker payloads.
//

import Foundation

struct BackgroundTaskArtifactCitation: Codable, Sendable, Equatable {
    let url: String
    let title: String?
    let snippet: String

    init(
        url: String,
        title: String? = nil,
        snippet: String
    ) {
        self.url = url
        self.title = title
        self.snippet = snippet
    }
}

struct BackgroundTaskArtifactPage: Codable, Sendable, Equatable {
    let pageNumber: Int
    let url: String
    let title: String?
    let extractedText: String
    let rawHTML: String?

    init(
        pageNumber: Int,
        url: String,
        title: String? = nil,
        extractedText: String,
        rawHTML: String? = nil
    ) {
        self.pageNumber = max(1, pageNumber)
        self.url = url
        self.title = title
        self.extractedText = extractedText
        self.rawHTML = rawHTML
    }
}

struct BackgroundTaskWorkerResult: Codable, Sendable, Equatable {
    let title: String
    let summary: String
    let markdown: String
    let pages: [BackgroundTaskArtifactPage]
    let citations: [BackgroundTaskArtifactCitation]

    init(
        title: String,
        summary: String,
        markdown: String,
        pages: [BackgroundTaskArtifactPage],
        citations: [BackgroundTaskArtifactCitation]
    ) {
        self.title = title
        self.summary = summary
        self.markdown = markdown
        self.pages = pages
        self.citations = citations
    }
}

struct ArtifactManifest: Codable, Sendable, Equatable {
    let taskID: UUID
    let taskKind: String
    let label: String?
    let query: String?
    let sourceURLs: [String]
    let artifactPath: String
    let createdAt: Date
    let completedAt: Date
    let citationCount: Int
    let pageCount: Int
    let rawHTMLPageCount: Int
    let domainsUsed: [String]?
}

struct ArtifactStoredPage: Codable, Sendable, Equatable {
    let pageNumber: Int
    let url: String
    let title: String?
    let extractedText: String
    let rawHTMLFilename: String?
}

struct ArtifactResult: Codable, Sendable, Equatable {
    let taskID: UUID
    let taskKind: String
    let label: String?
    let query: String?
    let sourceURLs: [String]
    let title: String
    let summary: String
    let markdown: String
    let pages: [ArtifactStoredPage]
    let createdAt: Date
    let completedAt: Date
    let provenance: ArtifactProvenance?
}

/// Full provenance detail stored in result.json.
struct ArtifactProvenance: Codable, Sendable, Equatable {
    let searchQueries: [String]?
    let discoveryRationale: String?
    let domainsUsed: [String]?
}

struct ArtifactRawHTMLPage: Sendable, Equatable {
    let pageNumber: Int
    let filename: String
    let html: String
}

struct StoredArtifact: Sendable, Equatable {
    let manifest: ArtifactManifest
    let result: ArtifactResult
    let citations: [BackgroundTaskArtifactCitation]
    let rawHTMLPages: [ArtifactRawHTMLPage]
}
