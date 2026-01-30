//
//  SentenceChunker.swift
//  Ora
//
//  Splits streaming text into sentence-sized chunks for early TTS.
//

import Foundation
import NaturalLanguage
import OSLog

struct SentenceChunker: Sendable {

    private static let logger = Logger(subsystem: "com.ora.app", category: "chunker")

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
        let bufferLen = buffer.count
        Self.logger.debug("Token: '\(token, privacy: .public)' → buffer[\(bufferLen)]")

        var ready: [String] = []
        let sentences = extractCompleteSentences(from: &buffer)

        if !sentences.isEmpty {
            let remainingLen = buffer.count
            Self.logger.debug("Extracted \(sentences.count) sentence(s), remaining buffer[\(remainingLen)]")
        }

        for sentence in sentences {
            let combined = joinSegments(pending, sentence)
            let normalized = normalizeForSpeech(combined)
            if normalized.count < minSentenceLength {
                pending = normalized
                let minLen = minSentenceLength
                Self.logger.debug("Too short (\(normalized.count) < \(minLen)), pending: '\(normalized, privacy: .public)'")
                continue
            }
            let chunks = splitOversizedChunk(normalized)
            ready.append(contentsOf: chunks)
            let chunkSizes = chunks.map { "[\($0.count)]" }.joined(separator: ", ")
            Self.logger.notice("Emit \(chunks.count) chunk(s): \(chunkSizes, privacy: .public)")
            pending = ""
        }

        let combinedBuffer = joinSegments(pending, buffer)
        if combinedBuffer.count > maxChunkLength {
            let segments = splitOversizedChunk(combinedBuffer)
            if segments.count > 1 {
                let emitted = segments.dropLast().map { normalizeForSpeech($0) }
                ready.append(contentsOf: emitted)
                buffer = segments.last ?? ""
                pending = ""
                let keepLen = buffer.count
                Self.logger.notice("Oversized split: emitting \(segments.count - 1) chunk(s), keeping buffer[\(keepLen)]")
            }
        }

        return ready
    }

    mutating func finalize() -> [String] {
        let pendingLen = pending.count
        let bufferLen = buffer.count
        let combined = joinSegments(pending, buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        Self.logger.notice("Finalize: pending[\(pendingLen)] + buffer[\(bufferLen)] = combined[\(combined.count)]")
        pending = ""
        buffer = ""

        let normalized = normalizeForSpeech(combined)
        guard !normalized.isEmpty else {
            Self.logger.debug("Finalize: nothing to emit")
            return []
        }
        let chunks = splitOversizedChunk(normalized)
        let chunkSizes = chunks.map { "[\($0.count)]" }.joined(separator: ", ")
        Self.logger.info("Finalize emit \(chunks.count) chunk(s): \(chunkSizes, privacy: .public)")
        return chunks
    }

    func chunk(tokens: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var working = self
                var totalTokens = 0
                var totalChunksEmitted = 0
                Self.logger.info("Chunker stream started")
                do {
                    for try await token in tokens {
                        totalTokens += 1
                        let sentences = working.consume(token)
                        for sentence in sentences {
                            totalChunksEmitted += 1
                            Self.logger.debug("Yield chunk #\(totalChunksEmitted): '\(sentence.prefix(50), privacy: .public)...' [\(sentence.count) chars]")
                            continuation.yield(sentence)
                        }
                    }
                    let remaining = working.finalize()
                    for sentence in remaining {
                        totalChunksEmitted += 1
                        Self.logger.debug("Yield final chunk #\(totalChunksEmitted): '\(sentence.prefix(50), privacy: .public)...' [\(sentence.count) chars]")
                        continuation.yield(sentence)
                    }
                    Self.logger.info("Chunker stream complete: \(totalTokens) tokens → \(totalChunksEmitted) chunks")
                    continuation.finish()
                } catch {
                    Self.logger.error("Chunker stream error: \(error.localizedDescription, privacy: .public)")
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
        logger.info("Static chunk: input[\(text.count) chars], minLen=\(minSentenceLength), maxLen=\(maxChunkLength)")
        var chunker = SentenceChunker(
            minSentenceLength: minSentenceLength,
            maxChunkLength: maxChunkLength
        )
        let sentences = chunker.consume(text)
        let result = sentences + chunker.finalize()
        logger.info("Static chunk result: \(result.count) chunk(s)")
        return result
    }

    static func normalizeText(_ text: String) -> String {
        var chunker = SentenceChunker()
        return chunker.normalizeForSpeech(text)
    }

    private func extractCompleteSentences(from buffer: inout String) -> [String] {
        guard !buffer.isEmpty else { return [] }

        let inputLen = buffer.count
        var sentences: [String] = []
        let endsWithNewline = buffer.hasSuffix("\n") || buffer.hasSuffix("\r")
        var index = buffer.startIndex
        var lastConsumed = buffer.startIndex

        var currentItem: String?
        var inNumberedList = false
        var listIndent = 0
        var proseBuffer = ""

        func flushProse() {
            let trimmed = proseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                proseBuffer = ""
                return
            }
            let proseSentences = tokenizeSentences(trimmed)
            for sentence in proseSentences {
                let normalized = normalizeForSpeech(sentence)
                if !normalized.isEmpty {
                    sentences.append(normalized)
                }
            }
            proseBuffer = ""
        }

        func flushItem() {
            let trimmed = currentItem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                currentItem = nil
                inNumberedList = false
                return
            }
            let normalized = normalizeForSpeech(trimmed)
            if !normalized.isEmpty {
                sentences.append(normalized)
            }
            currentItem = nil
            inNumberedList = false
        }

        while index < buffer.endIndex {
            let lineEnd = buffer[index...].firstIndex(of: "\n") ?? buffer.endIndex
            let isLastLine = lineEnd == buffer.endIndex
            if isLastLine && !endsWithNewline {
                break
            }

            let line = String(buffer[index..<lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                flushProse()
                flushItem()
                let nextIndex = lineEnd < buffer.endIndex ? buffer.index(after: lineEnd) : lineEnd
                lastConsumed = nextIndex
                index = nextIndex
                continue
            }

            if let item = parseNumberedItem(line) {
                flushProse()
                flushItem()
                let label = "\(item.number))"
                if item.content.isEmpty {
                    currentItem = label
                } else {
                    currentItem = "\(label) \(item.content)"
                }
                inNumberedList = true
                listIndent = item.indent
            } else if let bullet = parseBulletItem(line) {
                flushProse()
                if inNumberedList {
                    currentItem = appendListFragment(currentItem ?? "", fragment: bullet.content)
                } else {
                    flushItem()
                    currentItem = bullet.content
                    inNumberedList = false
                    listIndent = bullet.indent
                }
            } else {
                let indent = leadingWhitespaceCount(line)
                if let item = currentItem {
                    if inNumberedList || indent > listIndent {
                        currentItem = appendListFragment(item, fragment: trimmed)
                    } else {
                        flushItem()
                        proseBuffer = joinSegments(proseBuffer, trimmed)
                    }
                } else {
                    proseBuffer = joinSegments(proseBuffer, trimmed)
                }
            }

            let nextIndex = lineEnd < buffer.endIndex ? buffer.index(after: lineEnd) : lineEnd
            lastConsumed = nextIndex
            index = nextIndex
        }

        if endsWithNewline {
            flushProse()
            flushItem()
            lastConsumed = buffer.endIndex
        }

        var remainder = ""
        if lastConsumed > buffer.startIndex {
            remainder = String(buffer[lastConsumed...])
        }

        if !endsWithNewline, let item = currentItem, let bullet = parseBulletItem(remainder) {
            currentItem = appendListFragment(item, fragment: bullet.content)
            let normalized = normalizeForSpeech(currentItem ?? "")
            if !normalized.isEmpty {
                sentences.append(normalized)
            }
            currentItem = nil
            remainder = ""
        }

        if lastConsumed > buffer.startIndex {
            if endsWithNewline {
                buffer = remainder
            } else {
                let pending = joinSegments(currentItem ?? "", proseBuffer)
                buffer = joinSegments(pending, remainder)
            }
        } else if !endsWithNewline {
            let pending = joinSegments(currentItem ?? "", proseBuffer)
            if !pending.isEmpty {
                buffer = pending
            }
        }

        if lastConsumed == buffer.startIndex && !endsWithNewline && sentences.isEmpty {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let proseSentences = tokenizeSentences(trimmed)
                if !proseSentences.isEmpty {
                    var remainderSentence = ""
                    for (index, sentence) in proseSentences.enumerated() {
                        if index == proseSentences.count - 1 && !isCompleteSentence(sentence) {
                            remainderSentence = sentence
                            continue
                        }
                        let normalized = normalizeForSpeech(sentence)
                        if !normalized.isEmpty {
                            sentences.append(normalized)
                        }
                    }
                    buffer = remainderSentence
                }
            }
        }

        let remainingLen = buffer.count
        Self.logger.notice("extractCompleteSentences: input[\(inputLen)] → \(sentences.count) sentences, remaining[\(remainingLen)]")

        return sentences
    }

    private func isCompleteSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceEndings.contains(last)
    }

    private var sentenceEndings: Set<Character> {
        [".", "!", "?"]
    }

    private func normalizeForSpeech(_ text: String) -> String {
        let stripped = stripMarkdown(text)
        let ranged = normalizeDateRanges(stripped)
        let dated = normalizeSingleDates(ranged)
        return normalizeTimeRanges(dated)
    }

    private func stripMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: "(?s)```(.*?)```",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(^|\\s)\\*(\\S[^*]*?)\\*(?=\\s|$)",
            with: "$1$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(^|\\s)_(\\S[^_]*?)_(?=\\s|$)",
            with: "$1$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?m)^\\s*#{1,6}\\s*",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?m)^\\s*[-*•]\\s+",
            with: "",
            options: .regularExpression
        )
        return result
    }

    private func normalizeDateRanges(_ text: String) -> String {
        let pattern = "(?i)\\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\s+(\\d{1,2})\\s*[-–]\\s*(\\d{1,2})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        if matches.isEmpty { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let month = nsText.substring(with: match.range(at: 1))
            let startText = nsText.substring(with: match.range(at: 2))
            let endText = nsText.substring(with: match.range(at: 3))
            guard let start = Int(startText), let end = Int(endText) else { continue }
            let startWord = ordinalDayString(start)
            let endWord = ordinalDayString(end)
            let replacement = "\(month) \(startWord) to \(endWord)"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private func normalizeSingleDates(_ text: String) -> String {
        let pattern = "(?i)\\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\s+(\\d{1,2})(?!\\s*[-–])(?!\\d)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        if matches.isEmpty { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let month = nsText.substring(with: match.range(at: 1))
            let dayText = nsText.substring(with: match.range(at: 2))
            guard let day = Int(dayText) else { continue }
            let replacement = "\(month) \(ordinalDayString(day))"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private func normalizeTimeRanges(_ text: String) -> String {
        let pattern = "\\b([01]?\\d|2[0-3]):([0-5]\\d)\\s*[-–]\\s*([01]?\\d|2[0-3]):([0-5]\\d)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        if matches.isEmpty { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 5 else { continue }
            let startHourText = nsText.substring(with: match.range(at: 1))
            let startMinuteText = nsText.substring(with: match.range(at: 2))
            let endHourText = nsText.substring(with: match.range(at: 3))
            let endMinuteText = nsText.substring(with: match.range(at: 4))
            guard
                let startHour = Int(startHourText),
                let startMinute = Int(startMinuteText),
                let endHour = Int(endHourText),
                let endMinute = Int(endMinuteText)
            else { continue }
            let startSpoken = spoken24HourTime(hour: startHour, minute: startMinute)
            let endSpoken = spoken24HourTime(hour: endHour, minute: endMinute)
            let replacement = "\(startSpoken) to \(endSpoken)"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private func ordinalDayString(_ value: Int) -> String {
        switch value {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        case 5: return "fifth"
        case 6: return "sixth"
        case 7: return "seventh"
        case 8: return "eighth"
        case 9: return "ninth"
        case 10: return "tenth"
        case 11: return "eleventh"
        case 12: return "twelfth"
        case 13: return "thirteenth"
        case 14: return "fourteenth"
        case 15: return "fifteenth"
        case 16: return "sixteenth"
        case 17: return "seventeenth"
        case 18: return "eighteenth"
        case 19: return "nineteenth"
        case 20: return "twentieth"
        case 21: return "twenty first"
        case 22: return "twenty second"
        case 23: return "twenty third"
        case 24: return "twenty fourth"
        case 25: return "twenty fifth"
        case 26: return "twenty sixth"
        case 27: return "twenty seventh"
        case 28: return "twenty eighth"
        case 29: return "twenty ninth"
        case 30: return "thirtieth"
        case 31: return "thirty first"
        default: return String(value)
        }
    }

    private func spoken24HourTime(hour: Int, minute: Int) -> String {
        let hourText = cardinalNumberString(hour)
        if minute == 0 {
            return "\(hourText) hundred"
        }
        let minuteText: String
        if minute < 10 {
            minuteText = "oh \(cardinalNumberString(minute))"
        } else {
            minuteText = cardinalNumberString(minute)
        }
        return "\(hourText) \(minuteText)"
    }

    private func cardinalNumberString(_ value: Int) -> String {
        let ones: [String] = [
            "zero",
            "one",
            "two",
            "three",
            "four",
            "five",
            "six",
            "seven",
            "eight",
            "nine",
            "ten",
            "eleven",
            "twelve",
            "thirteen",
            "fourteen",
            "fifteen",
            "sixteen",
            "seventeen",
            "eighteen",
            "nineteen"
        ]
        if value < ones.count {
            return ones[value]
        }
        let tensWords: [Int: String] = [
            2: "twenty",
            3: "thirty",
            4: "forty",
            5: "fifty"
        ]
        let tens = value / 10
        let onesValue = value % 10
        guard let tensWord = tensWords[tens] else {
            return String(value)
        }
        if onesValue == 0 {
            return tensWord
        }
        return "\(tensWord) \(ones[onesValue])"
    }

    private func tokenizeSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            sentences.append(sentence)
            return true
        }
        return sentences
    }

    private func parseNumberedItem(_ line: String) -> (number: String, content: String, indent: Int)? {
        let indent = leadingWhitespaceCount(line)
        var index = line.index(line.startIndex, offsetBy: indent)
        guard index < line.endIndex, line[index].isNumber else { return nil }

        var digits = ""
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }

        guard !digits.isEmpty, index < line.endIndex, line[index] == "." else { return nil }
        index = line.index(after: index)

        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        let content = String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (digits, content, indent)
    }

    private func parseBulletItem(_ line: String) -> (content: String, indent: Int)? {
        let indent = leadingWhitespaceCount(line)
        var index = line.index(line.startIndex, offsetBy: indent)
        guard index < line.endIndex else { return nil }
        let marker = line[index]
        guard marker == "-" || marker == "*" || marker == "•" else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index].isWhitespace else { return nil }
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        let content = String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return (content, indent)
    }

    private func leadingWhitespaceCount(_ text: String) -> Int {
        var count = 0
        for character in text {
            if character == " " || character == "\t" {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private func appendListFragment(_ base: String, fragment: String) -> String {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        guard !base.isEmpty else { return trimmed }
        if base.hasSuffix(".") || base.hasSuffix("!") || base.hasSuffix("?") {
            return base + " " + trimmed
        }
        return base + ". " + trimmed
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

        Self.logger.debug("Splitting oversized chunk[\(trimmed.count)] (max \(self.maxChunkLength))")
        var result: [String] = []
        var remaining = trimmed

        while remaining.count > maxChunkLength {
            let splitIndex = findSplitIndex(in: remaining, maxLength: maxChunkLength)
            let head = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty {
                result.append(head)
                Self.logger.debug("Split piece[\(head.count)]: '\(head.prefix(30), privacy: .public)...'")
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
            Self.logger.debug("Split final[\(final.count)]: '\(final.prefix(30), privacy: .public)...'")
        }

        Self.logger.debug("Split complete: \(result.count) pieces")
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
