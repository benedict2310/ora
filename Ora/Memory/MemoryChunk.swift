//
//  MemoryChunk.swift
//  Ora
//
//  Typed retrieval chunk returned by keyword memory search.
//

import Foundation

enum MemoryDocumentType: String, Sendable, Codable {
    case memory
    case summary
    case transcript
}

struct MemoryChunk: Sendable, Equatable {
    let content: String
    let documentType: MemoryDocumentType
    let sessionID: UUID?
    let turnNumber: Int?
    let sectionName: String
    let lastModified: Date
    let score: Double

    init(
        content: String,
        documentType: MemoryDocumentType,
        sessionID: UUID?,
        turnNumber: Int? = nil,
        sectionName: String,
        lastModified: Date,
        score: Double
    ) {
        self.content = content
        self.documentType = documentType
        self.sessionID = sessionID
        self.turnNumber = turnNumber
        self.sectionName = sectionName
        self.lastModified = lastModified
        self.score = score
    }
}
