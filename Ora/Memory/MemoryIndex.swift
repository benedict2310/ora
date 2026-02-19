//
//  MemoryIndex.swift
//  Ora
//
//  SQLite FTS5 + embeddings hybrid index for MEMORY.md, session summaries,
//  and lazily scoped transcript fallback chunks.
//

import Foundation
import SQLite3
import os

protocol MemoryIndexing: Sendable {
    func rebuild() async
    func search(query: String, limit: Int) async -> [MemoryChunk]
    func searchTranscriptFallback(
        query: String,
        summarySessionIDs: [UUID],
        recentSessionLimit: Int,
        limit: Int
    ) async -> [MemoryChunk]
}

extension MemoryIndexing {
    func searchTranscriptFallback(
        query: String,
        summarySessionIDs: [UUID],
        recentSessionLimit: Int,
        limit: Int
    ) async -> [MemoryChunk] {
        return []
    }
}

actor MemoryIndex: MemoryIndexing {

    // MARK: - Types

    struct IndexedChunk: Sendable {
        let content: String
        let documentType: MemoryDocumentType
        let sessionID: UUID?
        let sectionName: String
        let lastModified: Date
        let embedding: [Float]?

        init(
            content: String,
            documentType: MemoryDocumentType,
            sessionID: UUID?,
            sectionName: String,
            lastModified: Date,
            embedding: [Float]? = nil
        ) {
            self.content = content
            self.documentType = documentType
            self.sessionID = sessionID
            self.sectionName = sectionName
            self.lastModified = lastModified
            self.embedding = embedding
        }

        func withEmbedding(_ embedding: [Float]) -> IndexedChunk {
            return IndexedChunk(
                content: self.content,
                documentType: self.documentType,
                sessionID: self.sessionID,
                sectionName: self.sectionName,
                lastModified: self.lastModified,
                embedding: embedding
            )
        }
    }

    struct HybridCandidateRecord: Sendable {
        let rowID: Int64
        let lastModified: Date
        let bm25Score: Double
        let embedding: [Float]?

        func merged(with other: HybridCandidateRecord) -> HybridCandidateRecord {
            return HybridCandidateRecord(
                rowID: self.rowID,
                lastModified: self.lastModified,
                bm25Score: max(self.bm25Score, other.bm25Score),
                embedding: self.embedding ?? other.embedding
            )
        }

        func toHybridCandidate() -> HybridScorer.Candidate {
            return HybridScorer.Candidate(
                rowID: self.rowID,
                content: "",
                documentType: .memory,
                sessionID: nil,
                sectionName: "",
                lastModified: self.lastModified,
                bm25Score: self.bm25Score,
                embedding: self.embedding
            )
        }
    }

    struct TranscriptSessionSnapshot: Sendable {
        let sessionID: UUID
        let lastModified: Date
        let messages: [Session.Message]
    }

    struct TranscriptIndexedChunk: Sendable {
        let sessionID: UUID
        let turnNumber: Int
        let content: String
        let lastModified: Date
    }

    typealias TranscriptSessionLoader = @Sendable ([UUID], Int) async -> [TranscriptSessionSnapshot]

    // MARK: - Singleton

    static let shared = MemoryIndex()

    // MARK: - Constants

    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let maximumSearchLimit = 20
    static let minimumSearchTokenLength = 2
    static let minimumHybridScore = 0.10
    static let minimumKeywordCandidateLimit = 32
    static let keywordCandidateMultiplier = 8

    // MARK: - Properties

    let logger = Logger.ora(category: "memory")
    let memoryFileManager: MemoryFileManager
    let fileManager: FileManager
    let transcriptChunker: TranscriptChunker
    let transcriptSessionLoader: TranscriptSessionLoader
    let embeddingService: any EmbeddingServicing
    let hybridScorer: HybridScorer

    var databaseURL: URL {
        return self.memoryFileManager.memoryDirectory.appendingPathComponent(".index.sqlite", isDirectory: false)
    }

    // MARK: - Initialization

    init(
        memoryDirectory: URL? = nil,
        fileManager: FileManager = .default,
        transcriptChunker: TranscriptChunker = TranscriptChunker(),
        transcriptSessionLoader: @escaping TranscriptSessionLoader = MemoryIndex.defaultTranscriptSessionLoader,
        embeddingService: any EmbeddingServicing = EmbeddingService.shared,
        hybridScorer: HybridScorer = HybridScorer()
    ) {
        self.fileManager = fileManager
        self.memoryFileManager = MemoryFileManager(
            fileManager: fileManager,
            memoryDirectory: memoryDirectory
        )
        self.transcriptChunker = transcriptChunker
        self.transcriptSessionLoader = transcriptSessionLoader
        self.embeddingService = embeddingService
        self.hybridScorer = hybridScorer
    }

    // MARK: - Public API

    func rebuild() async {
        do {
            try self.memoryFileManager.ensureMemoryStructureExists()
            let chunks = try self.loadAllChunks()
            let embeddedChunks = try await self.embedChunks(chunks)

            let database = try self.openDatabase()
            defer {
                sqlite3_close(database)
            }

            try self.ensureSchema(database: database)
            try self.replaceMemoryIndexContents(chunks: embeddedChunks, database: database)
            // Reclaim disk space freed by DELETE — SQLite won't shrink the file without VACUUM
            try self.execute(sql: "VACUUM;", database: database)

            self.logger.debug("Memory index rebuilt with \(embeddedChunks.count) chunk(s)")
        } catch {
            self.logger.error("Failed to rebuild memory index: \(error.localizedDescription)")
        }
    }

    func search(query: String, limit: Int) async -> [MemoryChunk] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        let queryExpression = Self.makeFTSQueryExpression(from: normalizedQuery)
        let clampedLimit = min(max(limit, 1), Self.maximumSearchLimit)

        do {
            try self.memoryFileManager.ensureMemoryStructureExists()
            let database = try self.openDatabase()
            defer {
                sqlite3_close(database)
            }

            try self.ensureSchema(database: database)
            let queryEmbedding: [Float]
            do {
                queryEmbedding = try await self.embeddingService.embed(text: normalizedQuery)
            } catch {
                self.logger.warning("Embedding query failed, falling back to keyword search: \(error.localizedDescription)")
                return try self.searchIndexKeywordOnly(
                    expression: queryExpression,
                    limit: clampedLimit,
                    database: database
                )
            }

            if queryEmbedding.isEmpty {
                return try self.searchIndexKeywordOnly(
                    expression: queryExpression,
                    limit: clampedLimit,
                    database: database
                )
            }

            return try self.searchIndexHybrid(
                expression: queryExpression,
                queryEmbedding: queryEmbedding,
                limit: clampedLimit,
                database: database
            )
        } catch {
            self.logger.error("Memory index search failed: \(error.localizedDescription)")
            return []
        }
    }

    func searchTranscriptFallback(
        query: String,
        summarySessionIDs: [UUID],
        recentSessionLimit: Int,
        limit: Int
    ) async -> [MemoryChunk] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        let queryExpression = Self.makeFTSQueryExpression(from: normalizedQuery)
        guard !queryExpression.isEmpty else {
            return []
        }

        let clampedLimit = min(max(limit, 1), Self.maximumSearchLimit)

        do {
            try self.memoryFileManager.ensureMemoryStructureExists()
            let scopedChunks = await self.loadScopedTranscriptChunks(
                summarySessionIDs: summarySessionIDs,
                recentSessionLimit: recentSessionLimit
            )
            guard !scopedChunks.isEmpty else {
                self.logger.debug("Transcript fallback search skipped: no scoped transcript chunks available")
                return []
            }

            let database = try self.openDatabase()
            defer {
                sqlite3_close(database)
            }

            try self.ensureSchema(database: database)
            try self.replaceTranscriptIndexContents(chunks: scopedChunks, database: database)

            return try self.searchTranscriptIndex(
                expression: queryExpression,
                limit: clampedLimit,
                database: database
            )
        } catch {
            self.logger.error("Transcript fallback search failed: \(error.localizedDescription)")
            return []
        }
    }

}
enum MemoryIndexError: LocalizedError {
    case sqlite(String)
    case embedding(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return message
        case .embedding(let message):
            return message
        }
    }
}
