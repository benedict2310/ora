//
//  MemoryIndex.swift
//  Ora
//
//  SQLite FTS5 keyword index for MEMORY.md and session summaries.
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
    }

    // MARK: - Singleton

    static let shared = MemoryIndex()

    // MARK: - Constants

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let maximumSearchLimit = 20
    private static let minimumSearchTokenLength = 2

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "memory")
    private let memoryFileManager: MemoryFileManager
    private let fileManager: FileManager

    private var databaseURL: URL {
        return self.memoryFileManager.memoryDirectory.appendingPathComponent(".index.sqlite", isDirectory: false)
    }

    // MARK: - Initialization

    init(
        documentsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.memoryFileManager = MemoryFileManager(
            fileManager: fileManager,
            documentsDirectory: documentsDirectory
        )
    }

    // MARK: - Public API

    func rebuild() async {
        do {
            try self.memoryFileManager.ensureMemoryStructureExists()
            let chunks = try self.loadAllChunks()

            let database = try self.openDatabase()
            defer {
                sqlite3_close(database)
            }

            try self.ensureSchema(database: database)
            try self.replaceIndexContents(chunks: chunks, database: database)

            self.logger.debug("Memory index rebuilt with \(chunks.count) chunk(s)")
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
        guard !queryExpression.isEmpty else {
            return []
        }

        let clampedLimit = min(max(limit, 1), Self.maximumSearchLimit)

        do {
            let database = try self.openDatabase()
            defer {
                sqlite3_close(database)
            }

            try self.ensureSchema(database: database)
            return try self.searchIndex(
                expression: queryExpression,
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
    }

    // MARK: - Rebuild

    private func replaceIndexContents(chunks: [IndexedChunk], database: OpaquePointer) throws {
        try self.execute(sql: "BEGIN IMMEDIATE TRANSACTION;", database: database)

        do {
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
        let sql = """
        INSERT INTO memory_chunks (
            content,
            document_type,
            session_id,
            section_name,
            last_modified
        )
        VALUES (?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare insert statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(statement)
        }

        for chunk in chunks {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            self.bindText(chunk.content, at: 1, to: statement)
            self.bindText(chunk.documentType.rawValue, at: 2, to: statement)
            if let sessionID = chunk.sessionID {
                self.bindText(sessionID.uuidString, at: 3, to: statement)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            self.bindText(chunk.sectionName, at: 4, to: statement)
            sqlite3_bind_double(statement, 5, chunk.lastModified.timeIntervalSince1970)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw MemoryIndexError.sqlite("Failed to insert chunk: \(self.lastSQLiteError(database: database))")
            }
        }
    }

    // MARK: - Search

    private func searchIndex(
        expression: String,
        limit: Int,
        database: OpaquePointer
    ) throws -> [MemoryChunk] {
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
            throw MemoryIndexError.sqlite("Failed to prepare search statement: \(self.lastSQLiteError(database: database))")
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

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return message
        }
    }
}
