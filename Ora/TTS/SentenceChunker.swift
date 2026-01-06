//
//  SentenceChunker.swift
//  Ora
//
//  Splits streaming text into sentence-sized chunks for early TTS.
//

import Foundation
import NaturalLanguage

struct SentenceChunker: Sendable {

    static let defaultMinSentenceLength = 10
    static let defaultMaxChunkLength = 240

    private let minSentenceLength: Int
    private let maxChunkLength: Int

    private var buffer: String = ""
    private var pending: String = ""

    init(
        minSentenceLength: Int = SentenceChunker.defaultMinSentenceLength,
        maxChunkLength: Int = SentenceChunker.defaultMaxChunkLength
    ) {
        self.minSentenceLength = minSentenceLength
        self.maxChunkLength = maxChunkLength
    }

    mutating func consume(_ token: String) -> [String] {
        guard !token.isEmpty else { return [] }

        buffer.append(token)

        var ready: [String] = []
        let sentences = extractCompleteSentences(from: &buffer)
        for sentence in sentences {
            let combined = joinSegments(pending, sentence)
            if combined.count < minSentenceLength {
                pending = combined
                continue
            }
            ready.append(contentsOf: splitOversizedChunk(combined))
            pending = ""
        }

        if buffer.count > maxChunkLength {
            let segments = splitOversizedChunk(buffer)
            if segments.count > 1 {
                ready.append(contentsOf: segments.dropLast())
                buffer = segments.last ?? ""
            }
        }

        return ready
    }

    mutating func finalize() -> [String] {
        let combined = joinSegments(pending, buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        buffer = ""

        guard !combined.isEmpty else { return [] }
        return splitOversizedChunk(combined)
    }

    func chunk(tokens: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var working = self
                do {
                    for try await token in tokens {
                        let sentences = working.consume(token)
                        for sentence in sentences {
                            continuation.yield(sentence)
                        }
                    }
                    let remaining = working.finalize()
                    for sentence in remaining {
                        continuation.yield(sentence)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func chunk(
        text: String,
        minSentenceLength: Int = SentenceChunker.defaultMinSentenceLength,
        maxChunkLength: Int = SentenceChunker.defaultMaxChunkLength
    ) -> [String] {
        var chunker = SentenceChunker(
            minSentenceLength: minSentenceLength,
            maxChunkLength: maxChunkLength
        )
        let sentences = chunker.consume(text)
        return sentences + chunker.finalize()
    }

    private func extractCompleteSentences(from buffer: inout String) -> [String] {
        guard !buffer.isEmpty else { return [] }

        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = buffer

        var lastEnd = buffer.startIndex
        tokenizer.enumerateTokens(in: buffer.startIndex..<buffer.endIndex) { range, _ in
            let sentence = String(buffer[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }

            if isCompleteSentence(sentence) {
                sentences.append(sentence)
                lastEnd = range.upperBound
            }
            return true
        }

        if lastEnd > buffer.startIndex {
            buffer = String(buffer[lastEnd...])
        }

        return sentences
    }

    private func isCompleteSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceEndings.contains(last)
    }

    private var sentenceEndings: Set<Character> {
        [".", "!", "?"]
    }

    private func joinSegments(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if left.hasSuffix(" ") || right.hasPrefix(" ") {
            return left + right
        }
        return left + " " + right
    }

    private func splitOversizedChunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxChunkLength else { return [trimmed] }

        var result: [String] = []
        var remaining = trimmed

        while remaining.count > maxChunkLength {
            let splitIndex = findSplitIndex(in: remaining, maxLength: maxChunkLength)
            let head = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty {
                result.append(head)
            }
            var tail = String(remaining[splitIndex...])
            tail = trimLeadingWhitespace(tail)
            remaining = tail
            if remaining.isEmpty {
                break
            }
        }

        let final = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty {
            result.append(final)
        }

        return result
    }

    private func findSplitIndex(in text: String, maxLength: Int) -> String.Index {
        let limit = text.index(text.startIndex, offsetBy: maxLength)

        var splitIndex: String.Index?
        var index = text.startIndex
        while index < limit {
            let character = text[index]
            if character.isWhitespace || sentenceSplitCharacters.contains(character) {
                splitIndex = text.index(after: index)
            }
            index = text.index(after: index)
        }

        return splitIndex ?? limit
    }

    private var sentenceSplitCharacters: Set<Character> {
        [".", ",", "!", "?", ";", ":"]
    }

    private func trimLeadingWhitespace(_ text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return String(text[index...])
    }
}
