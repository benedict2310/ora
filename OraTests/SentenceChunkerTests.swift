//
//  SentenceChunkerTests.swift
//  OraTests
//
//  Tests for SentenceChunker
//

import XCTest
@testable import Ora

final class SentenceChunkerTests: XCTestCase {

    private func normalized(_ text: String) -> String {
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
        result = result.replacingOccurrences(
            of: "(?m)^\\s*(\\d+)\\.\\s*",
            with: "$1) ",
            options: .regularExpression
        )
        result = normalizeDateRanges(result)
        result = normalizeSingleDates(result)
        result = normalizeTimeRanges(result)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let replacement = "\(month) \(ordinalDayString(start)) to \(ordinalDayString(end))"
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

    private func chunkedOutput(_ text: String, minSentenceLength: Int = 10, maxChunkLength: Int = 240) -> String {
        let chunks = SentenceChunker.chunk(
            text: text,
            minSentenceLength: minSentenceLength,
            maxChunkLength: maxChunkLength
        )
        return chunks.joined(separator: " ")
    }

    func test_chunkerExtractsSentencesFromStream() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Hello there.")
            continuation.yield(" How are")
            continuation.yield(" you?")
            continuation.finish()
        }

        let chunker = SentenceChunker(minSentenceLength: 5, maxChunkLength: 200)
        let sentenceStream = chunker.chunk(tokens: stream)

        var results: [String] = []
        for try await sentence in sentenceStream {
            results.append(sentence)
        }

        XCTAssertEqual(results, ["Hello there.", "How are you?"])
    }

    func test_chunkerFlushesRemainingTextAtEnd() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("This is incomplete")
            continuation.finish()
        }

        let chunker = SentenceChunker(minSentenceLength: 5, maxChunkLength: 200)
        let sentenceStream = chunker.chunk(tokens: stream)

        var results: [String] = []
        for try await sentence in sentenceStream {
            results.append(sentence)
        }

        XCTAssertEqual(results, ["This is incomplete"])
    }

    func test_chunkerSplitsOversizedText() {
        var chunker = SentenceChunker(minSentenceLength: 1, maxChunkLength: 20)
        let longToken = String(repeating: "a", count: 55)

        var results = chunker.consume(longToken)
        results.append(contentsOf: chunker.finalize())

        XCTAssertTrue(results.count > 1)
        XCTAssertTrue(results.allSatisfy { $0.count <= 20 })
    }

    func test_chunkerCombinesShortSentences() {
        var chunker = SentenceChunker(minSentenceLength: 8, maxChunkLength: 200)

        let first = chunker.consume("Hi.")
        XCTAssertTrue(first.isEmpty)

        let second = chunker.consume(" This is longer.")
        let remaining = chunker.finalize()

        let combined = second + remaining
        XCTAssertEqual(combined, ["Hi. This is longer."])
    }

    func test_chunkerPreservesOrderWhenPendingAndBufferSplits() {
        var chunker = SentenceChunker(minSentenceLength: 10, maxChunkLength: 20)
        let first = chunker.consume("Hi.")

        XCTAssertTrue(first.isEmpty)

        let longText = String(repeating: "a", count: 40)
        let outputs = chunker.consume(" " + longText)

        XCTAssertTrue(outputs.count > 1)
        XCTAssertTrue(outputs.joined(separator: " ").hasPrefix("Hi."))
        XCTAssertTrue(outputs.joined().contains("aaaaa"))
    }

    func test_chunkerHandlesMarkdownNumberedList() {
        let output = chunkedOutput(ChunkerTestCorpus.calendarEventList)
        XCTAssertTrue(output.contains("1)"))
        XCTAssertTrue(output.contains("Elfie & Gerhard Skivacay"))
        XCTAssertTrue(output.contains("2)"))
        XCTAssertTrue(output.contains("PERFORM"))
    }

    func test_chunkerHandlesCalendarEventFormat() {
        let output = chunkedOutput(ChunkerTestCorpus.calendarEventList)
        XCTAssertTrue(output.contains("Calendar: Maddie & Bene"))
        XCTAssertTrue(output.contains("January twenty fourth to twenty ninth"))
        XCTAssertTrue(output.contains("January twenty fifth to twenty ninth"))
    }

    func test_chunkerHandlesCalendarWeekBulletList() {
        let output = chunkedOutput(ChunkerTestCorpus.calendarWeekBullets)
        XCTAssertTrue(output.contains("January twenty fifth"))
        XCTAssertTrue(output.contains("January twenty sixth"))
        XCTAssertTrue(output.contains("January twenty seventh"))
        XCTAssertTrue(output.contains("January twenty eighth"))
        XCTAssertTrue(output.contains("January twenty ninth"))
        XCTAssertTrue(output.contains("January thirtieth"))
        XCTAssertTrue(output.contains("February second"))
        XCTAssertTrue(output.contains("thirteen hundred to fourteen hundred"))
    }

    func test_chunkerPreservesAllContent() {
        let input = ChunkerTestCorpus.mixedContent
        let output = chunkedOutput(input)
        XCTAssertEqual(normalized(input), normalized(output))
    }

    func test_chunkerHandlesTextWithoutFinalPunctuation() {
        let output = chunkedOutput(ChunkerTestCorpus.noPunctuation)
        XCTAssertEqual(output, "The answer is 42")
    }

    func test_chunkerStripsBoldMarkdown() {
        let output = chunkedOutput("Here is **bold** text.")
        XCTAssertTrue(output.contains("Here is bold text."))
    }

    func test_chunkerStripsItalicMarkdown() {
        let output = chunkedOutput("This is *italic* and _more_ text.")
        XCTAssertTrue(output.contains("This is italic and more text."))
    }

    func test_chunkerPreservesUnderscoresInFilenames() {
        let output = chunkedOutput(ChunkerTestCorpus.filenames)
        XCTAssertTrue(output.contains("file_name_here.txt"))
        XCTAssertTrue(output.contains("IMG_2024_01_01.png"))
    }

    func test_chunkerPreservesUnderscoresInIdentifiers() {
        let output = chunkedOutput(ChunkerTestCorpus.filenames)
        XCTAssertTrue(output.contains("snake_case"))
    }

    func test_chunkerStripsHeaderMarkdown() {
        let output = chunkedOutput("""
        # Title
        This is body text.
        """)
        XCTAssertTrue(output.contains("Title"))
        XCTAssertFalse(output.contains("#"))
    }

    func test_chunkerStripsBulletMarkdown() {
        let output = chunkedOutput("""
        - Milk
        - Eggs
        """)
        XCTAssertTrue(output.contains("Milk"))
        XCTAssertTrue(output.contains("Eggs"))
        XCTAssertFalse(output.contains("- "))
    }

    func test_chunkerChunksByListItems() {
        let input = """
        1. **Elfie**
           - Calendar: Maddie & Bene
           - Date: January 24-29 (all day)
        """
        let chunks = SentenceChunker.chunk(text: input)
        XCTAssertTrue(chunks.contains { chunk in
            chunk.contains("1)") &&
            chunk.contains("Elfie") &&
            chunk.contains("Calendar: Maddie & Bene") &&
            chunk.contains("January twenty fourth to twenty ninth")
        })
    }

    func test_chunkerHandlesNestedFormatting() {
        let input = """
        ## **Header**
        - *Italic* item
        """
        let output = chunkedOutput(input)
        XCTAssertTrue(output.contains("Header"))
        XCTAssertTrue(output.contains("Italic item"))
        XCTAssertFalse(output.contains("#"))
        XCTAssertFalse(output.contains("*"))
    }

    func test_corpusCalendarEvents() {
        let input = ChunkerTestCorpus.calendarEventList
        let output = chunkedOutput(input)
        XCTAssertEqual(normalized(input), normalized(output))
    }

    func test_corpusBulletList() {
        let input = ChunkerTestCorpus.bulletList
        let output = chunkedOutput(input)
        XCTAssertEqual(normalized(input), normalized(output))
    }

    func test_corpusMixedContent() {
        let input = ChunkerTestCorpus.mixedContent
        let output = chunkedOutput(input)
        XCTAssertEqual(normalized(input), normalized(output))
    }

    func test_corpusLongParagraph() {
        let input = ChunkerTestCorpus.longParagraph
        let output = chunkedOutput(input, minSentenceLength: 1, maxChunkLength: 120)
        XCTAssertEqual(normalized(input), normalized(output))
    }

    func test_corpusFilenames() {
        let input = ChunkerTestCorpus.filenames
        let output = chunkedOutput(input)
        XCTAssertEqual(normalized(input), normalized(output))
    }
}
