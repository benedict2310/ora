//
//  HybridSearcher.swift
//  Ora
//
//  Hybrid semantic/keyword search implementation for MemoryIndex.
//

import Foundation
import SQLite3

extension MemoryIndex {
    // MARK: - Search

    func searchIndexHybrid(
        expression: String,
        queryEmbedding: [Float],
        limit: Int,
        database: OpaquePointer
    ) throws -> [MemoryChunk] {
        let candidates = try self.fetchHybridCandidates(
            expression: expression,
            limit: limit,
            database: database
        )

        guard !candidates.isEmpty else {
            return []
        }

        let scored = self.hybridScorer.rank(
            queryEmbedding: queryEmbedding,
            candidates: candidates
        )

        guard let topScore = scored.first?.chunk.score, topScore >= Self.minimumHybridScore else {
            return []
        }

        let topRanked = Array(scored.prefix(limit))
        let rowIDs = topRanked.map(\.rowID)
        let chunksByRowID = try self.fetchChunksByRowID(
            rowIDs: rowIDs,
            database: database
        )

        var output: [MemoryChunk] = []
        output.reserveCapacity(topRanked.count)

        for scoredChunk in topRanked {
            guard let chunk = chunksByRowID[scoredChunk.rowID] else {
                continue
            }

            output.append(
                MemoryChunk(
                    content: chunk.content,
                    documentType: chunk.documentType,
                    sessionID: chunk.sessionID,
                    sectionName: chunk.sectionName,
                    lastModified: chunk.lastModified,
                    score: scoredChunk.chunk.score,
                    embedding: scoredChunk.chunk.embedding
                )
            )
        }

        return output
    }

    func fetchHybridCandidates(
        expression: String,
        limit: Int,
        database: OpaquePointer
    ) throws -> [HybridScorer.Candidate] {
        var mergedByRowID: [Int64: HybridCandidateRecord] = [:]

        if !expression.isEmpty {
            let keywordLimit = Self.keywordCandidateLimit(for: limit)
            let keywordCandidates = try self.fetchKeywordCandidates(
                expression: expression,
                limit: keywordLimit,
                database: database
            )

            for candidate in keywordCandidates {
                mergedByRowID[candidate.rowID] = candidate
            }
        }

        let semanticCandidates = try self.fetchSemanticCandidates(
            database: database
        )

        for candidate in semanticCandidates {
            if let existing = mergedByRowID[candidate.rowID] {
                mergedByRowID[candidate.rowID] = existing.merged(with: candidate)
            } else {
                mergedByRowID[candidate.rowID] = candidate
            }
        }

        return mergedByRowID.values.map { record in
            return record.toHybridCandidate()
        }
    }

    func fetchKeywordCandidates(
        expression: String,
        limit: Int,
        database: OpaquePointer
    ) throws -> [HybridCandidateRecord] {
        let sql = """
        SELECT
            memory_chunks.rowid,
            memory_chunks.last_modified,
            -bm25(memory_chunks) AS bm25_score,
            e.embedding
        FROM memory_chunks
        LEFT JOIN memory_chunk_embeddings e ON e.chunk_rowid = memory_chunks.rowid
        WHERE memory_chunks MATCH ?
        ORDER BY bm25(memory_chunks)
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare keyword candidate statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(statement)
        }

        self.bindText(expression, at: 1, to: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var output: [HybridCandidateRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let record = Self.readScoringCandidateRecord(from: statement) else {
                continue
            }
            output.append(record)
        }

        return output
    }

    func fetchSemanticCandidates(
        database: OpaquePointer
    ) throws -> [HybridCandidateRecord] {
        let sql = """
        SELECT
            e.chunk_rowid,
            c.last_modified,
            0.0 AS bm25_score,
            e.embedding
        FROM memory_chunk_embeddings e
        JOIN memory_chunks c ON c.rowid = e.chunk_rowid
        WHERE e.embedding IS NOT NULL;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare semantic candidate statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(statement)
        }

        var output: [HybridCandidateRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let record = Self.readScoringCandidateRecord(from: statement) else {
                continue
            }
            output.append(record)
        }

        return output
    }

    static func readScoringCandidateRecord(from statement: OpaquePointer) -> HybridCandidateRecord? {
        let rowID = sqlite3_column_int64(statement, 0)
        let modifiedTimestamp = sqlite3_column_double(statement, 1)
        let bm25Score = sqlite3_column_double(statement, 2)
        let embedding = Self.readEmbedding(from: statement, index: 3)

        return HybridCandidateRecord(
            rowID: rowID,
            lastModified: Date(timeIntervalSince1970: modifiedTimestamp),
            bm25Score: bm25Score,
            embedding: embedding
        )
    }

    func fetchChunksByRowID(
        rowIDs: [Int64],
        database: OpaquePointer
    ) throws -> [Int64: MemoryChunk] {
        guard !rowIDs.isEmpty else {
            return [:]
        }

        let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ", ")
        let sql = """
        SELECT
            rowid,
            content,
            document_type,
            session_id,
            section_name,
            last_modified
        FROM memory_chunks
        WHERE rowid IN (\(placeholders));
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare ranked chunk lookup statement: \(self.lastSQLiteError(database: database))")
        }
        defer {
            sqlite3_finalize(statement)
        }

        for (offset, rowID) in rowIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(offset + 1), rowID)
        }

        var output: [Int64: MemoryChunk] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let contentText = sqlite3_column_text(statement, 1),
                let documentTypeText = sqlite3_column_text(statement, 2),
                let sectionNameText = sqlite3_column_text(statement, 4),
                let documentType = MemoryDocumentType(rawValue: String(cString: documentTypeText))
            else {
                continue
            }

            let rowID = sqlite3_column_int64(statement, 0)
            let content = String(cString: contentText)
            let sectionName = String(cString: sectionNameText)
            let sessionIDText = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let sessionID = sessionIDText.flatMap(UUID.init(uuidString:))
            let modifiedTimestamp = sqlite3_column_double(statement, 5)

            output[rowID] = MemoryChunk(
                content: content,
                documentType: documentType,
                sessionID: sessionID,
                sectionName: sectionName,
                lastModified: Date(timeIntervalSince1970: modifiedTimestamp),
                score: 0
            )
        }

        return output
    }

    func searchIndexKeywordOnly(
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

    func searchTranscriptIndex(
        expression: String,
        limit: Int,
        database: OpaquePointer
    ) throws -> [MemoryChunk] {
        let sql = """
        SELECT
            content,
            session_id,
            turn_number,
            last_modified,
            -bm25(transcript_chunks) AS score
        FROM transcript_chunks
        WHERE transcript_chunks MATCH ?
        ORDER BY bm25(transcript_chunks)
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoryIndexError.sqlite("Failed to prepare transcript search statement: \(self.lastSQLiteError(database: database))")
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
                let sessionIDText = sqlite3_column_text(statement, 1)
            else {
                continue
            }

            let content = String(cString: contentText)
            let sessionID = UUID(uuidString: String(cString: sessionIDText))
            let turnNumber = Int(sqlite3_column_int(statement, 2))
            let modifiedTimestamp = sqlite3_column_double(statement, 3)
            let score = sqlite3_column_double(statement, 4)

            guard let sessionID else {
                continue
            }

            output.append(
                MemoryChunk(
                    content: content,
                    documentType: .transcript,
                    sessionID: sessionID,
                    turnNumber: turnNumber,
                    sectionName: "Turn \(turnNumber)",
                    lastModified: Date(timeIntervalSince1970: modifiedTimestamp),
                    score: score
                )
            )
        }

        return output
    }

}
