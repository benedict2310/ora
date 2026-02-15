//
//  TranscriptChunker.swift
//  Ora
//
//  Chunks persisted transcript messages into Q/A turns.
//

import Foundation

struct TranscriptTurnChunk: Sendable, Equatable {
    let sessionID: UUID
    let turnNumber: Int
    let content: String
    let lastModified: Date
}

struct TranscriptChunker: Sendable {

    // MARK: - Public API

    func chunk(
        sessionID: UUID,
        messages: [Session.Message],
        lastModified: Date
    ) -> [TranscriptTurnChunk] {
        guard !messages.isEmpty else {
            return []
        }

        var output: [TranscriptTurnChunk] = []
        var pendingQuestion: String?
        var pendingResponses: [String] = []
        var turnNumber = 0

        func flushPendingTurn() {
            guard let pendingQuestion else {
                pendingResponses.removeAll(keepingCapacity: false)
                return
            }

            let responseBlock = pendingResponses.joined(separator: "\n")
            let content: String
            if responseBlock.isEmpty {
                content = "User: \(pendingQuestion)"
            } else {
                content = "User: \(pendingQuestion)\n\(responseBlock)"
            }

            turnNumber += 1
            output.append(
                TranscriptTurnChunk(
                    sessionID: sessionID,
                    turnNumber: turnNumber,
                    content: content,
                    lastModified: lastModified
                )
            )

            pendingResponses.removeAll(keepingCapacity: false)
        }

        for message in messages {
            let normalizedContent = Self.normalize(message.content)
            guard !normalizedContent.isEmpty else {
                continue
            }

            switch message.role {
            case .user:
                flushPendingTurn()
                pendingQuestion = normalizedContent

            case .assistant:
                guard pendingQuestion != nil else {
                    continue
                }
                pendingResponses.append("Assistant: \(normalizedContent)")

            case .tool:
                guard pendingQuestion != nil else {
                    continue
                }
                pendingResponses.append("Tool: \(normalizedContent)")
            }
        }

        flushPendingTurn()
        return output
    }

    // MARK: - Helpers

    private static func normalize(_ content: String) -> String {
        return content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
