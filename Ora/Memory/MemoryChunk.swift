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
}

struct MemoryChunk: Sendable, Equatable {
    let content: String
    let documentType: MemoryDocumentType
    let sessionID: UUID?
    let sectionName: String
    let lastModified: Date
    let score: Double
}

