//
//  MemoryIndex.swift
//  Ora
//
//  SQLite FTS5 + embeddings hybrid index for MEMORY.md and session summaries.
//

import Foundation
import SQLite3
import os

protocol MemoryIndexing: Sendable {
    func rebuild() async
    func search(query: String, limit: Int) async -> [MemoryChunk]
}

actor MemoryIndex: MemoryIndexing {

    // MARK: - Types

    private struct IndexedChunk: Sendable {
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

    // MARK: - Singleton

    static let shared = MemoryIndex()

    // MARK: - Constants

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let maximumSearchLimit = 20
    private static let minimumSearchTokenLength = 2
    private static let minimumHybridScore = 0.10

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "memory")
    private let memoryFileManager: MemoryFileManager
    private let fileManager: FileManager
    private let embeddingService: any EmbeddingServicing
    private let hybridScorer: HybridScorer

    private var databaseURL: URL {
        return self.memoryFileManager.memoryDirectory.appendingPathComponent(".index.sqlite", isDirectory: false)
    }

    // MARK: - Initialization

    init(
        documentsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        embeddingService: any EmbeddingServicing = EmbeddingService.shared,
        hybridScorer: HybridScorer = HybridScorer()
    ) {
        self.fileManager = fileManager
        self.memoryFileManager = MemoryFileManager(
            fileManager: fileManager,
            documentsDirectory: documentsDirectory
        )
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
            try self.replaceIndexContents(chunks: embeddedChunks, database: database)

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

    // MARK: - Schema

    private func ensureSchema(database: OpaquePointer) throws {
        try self.execute(
            sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_chunks USING fts5(
                content,
                document_type UNINDEXED,
                session_id UNINDEXED,
                section_name UNINDEXED,
                last_modified UNINDEXED,
                tokenize = 'unicode61'
            );
            """,
            database: database
        )

        if self.embeddingTableNeedsMigration(database: database) {
            try self.execute(sql: "DROP TABLE IF EXISTS memory_chunk_embeddings;", database: database)
        }

        try self.execute(
            sql: """
            CREATE TABLE IF NOT EXISTS memory_chunk_embeddings (
                chunk_rowid INTEGER PRIMARY KEY,
                embedding BLOB
            );
            """,
            database: database
        )
    }

    // MARK: - Rebuild

    private func replaceIndexContents(chunks: [IndexedChunk], database: OpaquePointer) throws {
        try self.execute(sql: "BEGIN IMMEDIATE TRANSACTION;", database: database)

        do {
            try self.execute(sql: "DELETE FROM memory_chunk_embeddings;", database: database)
            try self.execute(sql: "DELETE FROM memory_chunks;", database: database)

            if !chunks.isEmpty {
                try self.insert(chunks: chunks, database: database)
            }

            try self.execute(sql: "COMMIT;", database: database)
        } catch {
            _ = try? self.execute(sql: "ROLLBACK;", database: database)
            throw error
        }
    }

    private func insert(chunks: [IndexedChunk], database: OpaquePointer) throws {
        let chunkSQL = """
        INSERT INTO memory_chunks (
            content,
            document_type,
            session_id,
            section_name,
            last_modified
        )
        VALUES (?, ?, ?, ?, ?);
        """

        let embeddingSQL = """
        INSERT INTO memory_chunk_embeddings (
            chunk_rowid,
            embedding
        )
        VALUES (?, ?);
        """

        var chunkStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, chunkSQL, -1, &chunkStatement, nil) == SQLITE_OK, let chunkStatement else {
            throw MemoryIndexError.sqlite("Failed to prepare insert chunk statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(chunkStatement)
        }

        var embeddingStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, embeddingSQL, -1, &embeddingStatement, nil) == SQLITE_OK, let embeddingStatement else {
            throw MemoryIndexError.sqlite("Failed to prepare insert embedding statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(embeddingStatement)
        }

        for chunk in chunks {
            sqlite3_reset(chunkStatement)
            sqlite3_clear_bindings(chunkStatement)

            self.bindText(chunk.content, at: 1, to: chunkStatement)
            self.bindText(chunk.documentType.rawValue, at: 2, to: chunkStatement)
            if let sessionID = chunk.sessionID {
                self.bindText(sessionID.uuidString, at: 3, to: chunkStatement)
            } else {
                sqlite3_bind_null(chunkStatement, 3)
            }
            self.bindText(chunk.sectionName, at: 4, to: chunkStatement)
            sqlite3_bind_double(chunkStatement, 5, chunk.lastModified.timeIntervalSince1970)

            if sqlite3_step(chunkStatement) != SQLITE_DONE {
                throw MemoryIndexError.sqlite("Failed to insert chunk: \(self.lastSQLiteError(database: database))")
            }

            let rowID = sqlite3_last_insert_rowid(database)

            sqlite3_reset(embeddingStatement)
            sqlite3_clear_bindings(embeddingStatement)

            sqlite3_bind_int64(embeddingStatement, 1, rowID)
            if let embedding = chunk.embedding {
                let data = Self.serializeEmbedding(embedding)
                data.withUnsafeBytes { rawBuffer in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress
                    sqlite3_bind_blob(embeddingStatement, 2, bytes, Int32(data.count), Self.sqliteTransient)
                }
            } else {
                sqlite3_bind_null(embeddingStatement, 2)
            }

            if sqlite3_step(embeddingStatement) != SQLITE_DONE {
                throw MemoryIndexError.sqlite("Failed to insert embedding: \(self.lastSQLiteError(database: database))")
            }
        }
    }

    private func embedChunks(_ chunks: [IndexedChunk]) async throws -> [IndexedChunk] {
        guard !chunks.isEmpty else {
            return []
        }

        let texts = chunks.map(\.content)
        let embeddings = try await self.embeddingService.embed(texts: texts)

        guard embeddings.count == chunks.count else {
            throw MemoryIndexError.embedding("Embedding count mismatch")
        }

        return zip(chunks, embeddings).map { chunk, embedding in
            return chunk.withEmbedding(embedding)
        }
    }

    // MARK: - Search

    private func searchIndexHybrid(
        expression: String,
        queryEmbedding: [Float],
        limit: Int,
        database: OpaquePointer
    ) throws -> [MemoryChunk] {
        let candidates = try self.fetchHybridCandidates(
            expression: expression,
            database: database
        )

        guard !candidates.isEmpty else {
            return []
        }

        let scored = self.hybridScorer.rank(
            queryEmbedding: queryEmbedding,
            candidates: candidates
        )

        let rankedChunks = Array(scored.prefix(limit).map(\.chunk))
        guard let topChunk = rankedChunks.first, topChunk.score >= Self.minimumHybridScore else {
            return []
        }

        return rankedChunks
    }

    private func fetchHybridCandidates(
        expression: String,
        database: OpaquePointer
    ) throws -> [HybridScorer.Candidate] {
        let hasKeywordExpression = !expression.isEmpty
        let sql: String

        if hasKeywordExpression {
            sql = """
            WITH keyword_scores AS (
                SELECT
                    rowid AS chunk_rowid,
                    -bm25(memory_chunks) AS bm25_score
                FROM memory_chunks
                WHERE memory_chunks MATCH ?
            )
            SELECT
                c.content,
                c.document_type,
                c.session_id,
                c.section_name,
                c.last_modified,
                COALESCE(k.bm25_score, 0.0) AS bm25_score,
                e.embedding
            FROM memory_chunks c
            LEFT JOIN keyword_scores k ON k.chunk_rowid = c.rowid
            LEFT JOIN memory_chunk_embeddings e ON e.chunk_rowid = c.rowid;
            """
        } else {
            sql = """
            SELECT
                c.content,
                c.document_type,
                c.session_id,
                c.section_name,
                c.last_modified,
                0.0 AS bm25_score,
                e.embedding
            FROM memory_chunks c
            LEFT JOIN memory_chunk_embeddings e ON e.chunk_rowid = c.rowid;
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare hybrid search statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(statement)
        }

        if hasKeywordExpression {
            self.bindText(expression, at: 1, to: statement)
        }

        var output: [HybridScorer.Candidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let contentText = sqlite3_column_text(statement, 0),
                let documentTypeText = sqlite3_column_text(statement, 1),
                let sectionNameText = sqlite3_column_text(statement, 3),
                let documentType = MemoryDocumentType(rawValue: String(cString: documentTypeText))
            else {
                continue
            }

            let content = String(cString: contentText)
            let sectionName = String(cString: sectionNameText)
            let sessionIDText = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let sessionID = sessionIDText.flatMap(UUID.init(uuidString:))
            let modifiedTimestamp = sqlite3_column_double(statement, 4)
            let bm25Score = sqlite3_column_double(statement, 5)
            let embedding = Self.readEmbedding(from: statement, index: 6)

            output.append(
                HybridScorer.Candidate(
                    content: content,
                    documentType: documentType,
                    sessionID: sessionID,
                    sectionName: sectionName,
                    lastModified: Date(timeIntervalSince1970: modifiedTimestamp),
                    bm25Score: bm25Score,
                    embedding: embedding
                )
            )
        }

        return output
    }

    private func searchIndexKeywordOnly(
        expression: String,
        limit: Int,
        database: OpaquePointer
    ) throws -> [MemoryChunk] {
        guard !expression.isEmpty else {
            return []
        }

        let sql = """
        SELECT
            content,
            document_type,
            session_id,
            section_name,
            last_modified,
            -bm25(memory_chunks) AS score
        FROM memory_chunks
        WHERE memory_chunks MATCH ?
        ORDER BY bm25(memory_chunks)
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare keyword search statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(statement)
        }

        self.bindText(expression, at: 1, to: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var output: [MemoryChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let contentText = sqlite3_column_text(statement, 0),
                let documentTypeText = sqlite3_column_text(statement, 1),
                let sectionNameText = sqlite3_column_text(statement, 3),
                let documentType = MemoryDocumentType(rawValue: String(cString: documentTypeText))
            else {
                continue
            }

            let content = String(cString: contentText)
            let sectionName = String(cString: sectionNameText)
            let sessionIDText = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let sessionID = sessionIDText.flatMap(UUID.init(uuidString:))
            let modifiedTimestamp = sqlite3_column_double(statement, 4)
            let score = sqlite3_column_double(statement, 5)

            output.append(
                MemoryChunk(
                    content: content,
                    documentType: documentType,
                    sessionID: sessionID,
                    sectionName: sectionName,
                    lastModified: Date(timeIntervalSince1970: modifiedTimestamp),
                    score: score
                )
            )
        }

        return output
    }

    // MARK: - File Parsing

    private func loadAllChunks() throws -> [IndexedChunk] {
        var chunks: [IndexedChunk] = []
        chunks.append(contentsOf: try self.loadMemoryChunks())
        chunks.append(contentsOf: try self.loadSummaryChunks())
        return chunks
    }

    private func loadMemoryChunks() throws -> [IndexedChunk] {
        let memoryURL = self.memoryFileManager.memoryFileURL
        guard self.fileManager.fileExists(atPath: memoryURL.path) else {
            return []
        }

        let content = try String(contentsOf: memoryURL, encoding: .utf8)
        let lastModified = self.lastModifiedDate(for: memoryURL)

        var currentSection = "General"
        var chunks: [IndexedChunk] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if trimmed.hasPrefix("## ") {
                currentSection = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            if trimmed.hasPrefix("#") {
                continue
            }

            let normalized = Self.normalizeMarkdownText(trimmed)
            guard !normalized.isEmpty else {
                continue
            }

            chunks.append(
                IndexedChunk(
                    content: normalized,
                    documentType: .memory,
                    sessionID: nil,
                    sectionName: currentSection,
                    lastModified: lastModified
                )
            )
        }

        return chunks
    }

    private func loadSummaryChunks() throws -> [IndexedChunk] {
        let summariesURL = self.memoryFileManager.summariesDirectory
        guard self.fileManager.fileExists(atPath: summariesURL.path) else {
            return []
        }

        let summaryURLs = try self.fileManager.contentsOfDirectory(
            at: summariesURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "md" }

        var chunks: [IndexedChunk] = []
        for summaryURL in summaryURLs {
            let content = try String(contentsOf: summaryURL, encoding: .utf8)
            let sessionID = UUID(uuidString: summaryURL.deletingPathExtension().lastPathComponent)
            let lastModified = self.lastModifiedDate(for: summaryURL)
            chunks.append(
                contentsOf: self.chunkSummaryMarkdown(
                    content: content,
                    sessionID: sessionID,
                    lastModified: lastModified
                )
            )
        }

        return chunks
    }

    private func chunkSummaryMarkdown(
        content: String,
        sessionID: UUID?,
        lastModified: Date
    ) -> [IndexedChunk] {
        var chunks: [IndexedChunk] = []
        var currentSection = "Session Summary"
        var currentLines: [String] = []

        func flushCurrentChunk() {
            let combined = currentLines
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combined.isEmpty else {
                currentLines = []
                return
            }

            chunks.append(
                IndexedChunk(
                    content: combined,
                    documentType: .summary,
                    sessionID: sessionID,
                    sectionName: currentSection,
                    lastModified: lastModified
                )
            )
            currentLines = []
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if trimmed.hasPrefix("## ") {
                flushCurrentChunk()
                currentSection = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            if trimmed.hasPrefix("# ") {
                continue
            }

            let normalized = Self.normalizeMarkdownText(trimmed)
            guard !normalized.isEmpty else {
                continue
            }

            currentLines.append(normalized)
        }

        flushCurrentChunk()
        return chunks
    }

    private func lastModifiedDate(for fileURL: URL) -> Date {
        guard
            let fileAttributes = try? self.fileManager.attributesOfItem(atPath: fileURL.path),
            let modifiedDate = fileAttributes[.modificationDate] as? Date
        else {
            return Date()
        }

        return modifiedDate
    }

    // MARK: - SQLite Utilities

    private func openDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(self.databaseURL.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let errorMessage = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw MemoryIndexError.sqlite("Failed to open index database: \(errorMessage)")
        }

        _ = sqlite3_exec(database, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return database
    }

    private func execute(sql: String, database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw MemoryIndexError.sqlite("SQLite execute failed: \(self.lastSQLiteError(database: database))")
        }
    }

    private func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func lastSQLiteError(database: OpaquePointer) -> String {
        return String(cString: sqlite3_errmsg(database))
    }

    private func embeddingTableNeedsMigration(database: OpaquePointer) -> Bool {
        let sql = """
        SELECT sql
        FROM sqlite_master
        WHERE type = 'table'
          AND name = 'memory_chunk_embeddings'
        LIMIT 1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return false
        }

        guard let schemaText = sqlite3_column_text(statement, 0) else {
            return false
        }

        let schema = String(cString: schemaText)
        return schema.localizedCaseInsensitiveContains("FOREIGN KEY")
    }

    private static func serializeEmbedding(_ embedding: [Float]) -> Data {
        return embedding.withUnsafeBufferPointer { buffer in
            return Data(buffer: buffer)
        }
    }

    private static func deserializeEmbedding(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else {
            return nil
        }

        return data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }
    }

    private static func readEmbedding(from statement: OpaquePointer, index: Int32) -> [Float]? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let rawBytes = sqlite3_column_blob(statement, index) else {
            return nil
        }

        let data = Data(bytes: rawBytes, count: byteCount)
        return Self.deserializeEmbedding(data)
    }

    // MARK: - Query Normalization

    private static func makeFTSQueryExpression(from query: String) -> String {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { character in
                return !character.isLetter && !character.isNumber
            })
            .map(String.init)
            .filter { token in
                return token.count >= Self.minimumSearchTokenLength
            }

        guard !tokens.isEmpty else {
            return ""
        }

        return Array(Set(tokens))
            .sorted()
            .map { "\($0)*" }
            .joined(separator: " OR ")
    }

    private static func normalizeMarkdownText(_ text: String) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.hasPrefix("- ") {
            normalized = String(normalized.dropFirst(2))
        }

        normalized = normalized.replacingOccurrences(
            of: #"^\d+\.\s+"#,
            with: "",
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(
            of: #"[*_`]+"#,
            with: "",
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
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
