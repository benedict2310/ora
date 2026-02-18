//
//  TranscriptIndexer.swift
//  Ora
//
//  Transcript and markdown chunk indexing helpers for MemoryIndex.
//

import Foundation
import SQLite3

extension MemoryIndex {
    // MARK: - File Parsing

    func loadScopedTranscriptChunks(
        summarySessionIDs: [UUID],
        recentSessionLimit: Int
    ) async -> [TranscriptIndexedChunk] {
        let snapshots = await self.transcriptSessionLoader(
            Self.uniqueSessionIDs(summarySessionIDs),
            recentSessionLimit
        )

        var transcriptChunks: [TranscriptIndexedChunk] = []
        for snapshot in snapshots {
            let chunks = self.transcriptChunker.chunk(
                sessionID: snapshot.sessionID,
                messages: snapshot.messages,
                lastModified: snapshot.lastModified
            )

            transcriptChunks.append(
                contentsOf: chunks.map { chunk in
                    TranscriptIndexedChunk(
                        sessionID: chunk.sessionID,
                        turnNumber: chunk.turnNumber,
                        content: chunk.content,
                        lastModified: chunk.lastModified
                    )
                }
            )
        }

        return transcriptChunks
    }

    func loadAllChunks() throws -> [IndexedChunk] {
        var chunks: [IndexedChunk] = []
        chunks.append(contentsOf: try self.loadMemoryChunks())
        chunks.append(contentsOf: try self.loadSummaryChunks())
        return chunks
    }

    func loadMemoryChunks() throws -> [IndexedChunk] {
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

    func loadSummaryChunks() throws -> [IndexedChunk] {
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

    func chunkSummaryMarkdown(
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

    func lastModifiedDate(for fileURL: URL) -> Date {
        guard
            let fileAttributes = try? self.fileManager.attributesOfItem(atPath: fileURL.path),
            let modifiedDate = fileAttributes[.modificationDate] as? Date
        else {
            return Date()
        }

        return modifiedDate
    }

    static func defaultTranscriptSessionLoader(
        summarySessionIDs: [UUID],
        recentSessionLimit: Int
    ) async -> [TranscriptSessionSnapshot] {
        return await MainActor.run {
            let persistence = PersistenceManager.shared

            if !summarySessionIDs.isEmpty {
                return summarySessionIDs.compactMap { sessionID in
                    guard let messages = persistence.messageSnapshot(sessionId: sessionID),
                        !messages.isEmpty else {
                        return nil
                    }

                    return TranscriptSessionSnapshot(
                        sessionID: sessionID,
                        lastModified: messages.last?.timestamp ?? Date(),
                        messages: messages
                    )
                }
            }

            let recentSessions = persistence.recentSessions(limit: max(recentSessionLimit, 1))
            return recentSessions.compactMap { session in
                let messages = session.messages
                guard !messages.isEmpty else {
                    return nil
                }

                return TranscriptSessionSnapshot(
                    sessionID: session.id,
                    lastModified: session.updatedAt,
                    messages: messages
                )
            }
        }
    }

    // MARK: - SQLite Utilities

    func openDatabase() throws -> OpaquePointer {
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

    func execute(sql: String, database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw MemoryIndexError.sqlite("SQLite execute failed: \(self.lastSQLiteError(database: database))")
        }
    }

    func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    func lastSQLiteError(database: OpaquePointer) -> String {
        return String(cString: sqlite3_errmsg(database))
    }

    func embeddingTableNeedsMigration(database: OpaquePointer) -> Bool {
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

    static func serializeEmbedding(_ embedding: [Float]) -> Data {
        return embedding.withUnsafeBufferPointer { buffer in
            return Data(buffer: buffer)
        }
    }

    static func deserializeEmbedding(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else {
            return nil
        }

        return data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }
    }

    static func readEmbedding(from statement: OpaquePointer, index: Int32) -> [Float]? {
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

    static func uniqueSessionIDs(_ sessionIDs: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var output: [UUID] = []

        for sessionID in sessionIDs where !seen.contains(sessionID) {
            seen.insert(sessionID)
            output.append(sessionID)
        }

        return output
    }

    static func makeFTSQueryExpression(from query: String) -> String {
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

    static func keywordCandidateLimit(for limit: Int) -> Int {
        return max(
            Self.minimumKeywordCandidateLimit,
            limit * Self.keywordCandidateMultiplier
        )
    }

    static func normalizeMarkdownText(_ text: String) -> String {
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
