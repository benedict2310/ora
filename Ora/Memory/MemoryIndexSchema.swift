//
//  MemoryIndexSchema.swift
//  Ora
//
//  SQLite schema setup and transactional rebuild helpers.
//

import Foundation
import SQLite3

extension MemoryIndex {
    // MARK: - Schema

    func ensureSchema(database: OpaquePointer) throws {
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

        try self.execute(
            sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_chunks USING fts5(
                content,
                session_id UNINDEXED,
                turn_number UNINDEXED,
                last_modified UNINDEXED,
                tokenize = 'unicode61'
            );
            """,
            database: database
        )
    }

    // MARK: - Rebuild

    func replaceMemoryIndexContents(chunks: [IndexedChunk], database: OpaquePointer) throws {
        try self.execute(sql: "BEGIN IMMEDIATE TRANSACTION;", database: database)

        do {
            try self.execute(sql: "DELETE FROM memory_chunk_embeddings;", database: database)
            try self.execute(sql: "DELETE FROM memory_chunks;", database: database)

            if !chunks.isEmpty {
                try self.insertMemoryChunks(chunks: chunks, database: database)
            }

            try self.execute(sql: "COMMIT;", database: database)
        } catch {
            do {
                try self.execute(sql: "ROLLBACK;", database: database)
            } catch {
                self.logger.error("Failed to rollback memory index transaction: \(error.localizedDescription)")
            }
            throw error
        }
    }

    func insertMemoryChunks(chunks: [IndexedChunk], database: OpaquePointer) throws {
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

    func embedChunks(_ chunks: [IndexedChunk]) async throws -> [IndexedChunk] {
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

    func replaceTranscriptIndexContents(chunks: [TranscriptIndexedChunk], database: OpaquePointer) throws {
        try self.execute(sql: "BEGIN IMMEDIATE TRANSACTION;", database: database)

        do {
            try self.execute(sql: "DELETE FROM transcript_chunks;", database: database)

            if !chunks.isEmpty {
                try self.insertTranscriptChunks(chunks: chunks, database: database)
            }

            try self.execute(sql: "COMMIT;", database: database)
        } catch {
            do {
                try self.execute(sql: "ROLLBACK;", database: database)
            } catch {
                self.logger.error("Failed to rollback transcript index transaction: \(error.localizedDescription)")
            }
            throw error
        }
    }

    func insertTranscriptChunks(chunks: [TranscriptIndexedChunk], database: OpaquePointer) throws {
        let sql = """
        INSERT INTO transcript_chunks (
            content,
            session_id,
            turn_number,
            last_modified
        )
        VALUES (?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare transcript insert statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(statement)
        }

        for chunk in chunks {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            self.bindText(chunk.content, at: 1, to: statement)
            self.bindText(chunk.sessionID.uuidString, at: 2, to: statement)
            sqlite3_bind_int(statement, 3, Int32(chunk.turnNumber))
            sqlite3_bind_double(statement, 4, chunk.lastModified.timeIntervalSince1970)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw MemoryIndexError.sqlite("Failed to insert transcript chunk: \(self.lastSQLiteError(database: database))")
            }
        }
    }

}
