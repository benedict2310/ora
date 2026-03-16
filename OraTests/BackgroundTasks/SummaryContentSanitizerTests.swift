//
//  SummaryContentSanitizerTests.swift
//  OraTests
//
//  Tests for SummaryContentSanitizer HTML/Unicode stripping and truncation.
//

import XCTest
@testable import Ora

final class SummaryContentSanitizerTests: XCTestCase {

    private let sanitizer = SummaryContentSanitizer()

    // MARK: - HTML Stripping

    func test_sanitizer_stripsHTMLTags() {
        let pages = [SanitizablePageInput(
            url: "https://example.com",
            title: "Test",
            extractedText: "<p>Hello <b>world</b></p>"
        )]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].sanitizedText.contains("Hello world"))
        XCTAssertFalse(result[0].sanitizedText.contains("<p>"))
        XCTAssertFalse(result[0].sanitizedText.contains("<b>"))
        XCTAssertFalse(result[0].sanitizedText.contains("</b>"))
    }

    // MARK: - Whitespace Collapsing

    func test_sanitizer_collapsesWhitespace() {
        let pages = [SanitizablePageInput(
            url: "https://example.com",
            title: "Test",
            extractedText: "Hello     world\t\t\ttab\n\n\n\n\nmultiline"
        )]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        let text = result[0].sanitizedText
        // Runs of spaces/tabs should collapse to a single space
        XCTAssertTrue(text.contains("Hello world"))
        XCTAssertTrue(text.contains("tab"))
        // Multiple blank lines should collapse to at most two newlines
        XCTAssertFalse(text.contains("\n\n\n"))
    }

    // MARK: - Control Characters

    func test_sanitizer_stripsControlCharacters() {
        let controlChars = String(UnicodeScalar(0x00)) + String(UnicodeScalar(0x01)) + String(UnicodeScalar(0x07))
        let input = "Hello\(controlChars)World"
        let pages = [SanitizablePageInput(
            url: "https://example.com",
            title: "Test",
            extractedText: input
        )]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].sanitizedText.contains("HelloWorld"))
    }

    // MARK: - Per-Page Cap

    func test_sanitizer_capsPerPageAt4000() {
        let longText = String(repeating: "A", count: 5000)
        let pages = [SanitizablePageInput(
            url: "https://example.com",
            title: "Test",
            extractedText: longText
        )]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        // The sanitized text includes the delimiter wrapping, so the actual content
        // portion should be capped at 4000 chars
        let contentOnly = result[0].sanitizedText
            .replacingOccurrences(of: "[BEGIN FETCHED CONTENT FROM https://example.com]\n", with: "")
            .replacingOccurrences(of: "\n[END FETCHED CONTENT]", with: "")
        XCTAssertEqual(contentOnly.count, SummaryContentSanitizer.maxCharsPerPage)
    }

    // MARK: - Total Input Cap

    func test_sanitizer_capsTotalInputAt8000() {
        let pages = (0..<5).map { i in
            SanitizablePageInput(
                url: "https://example.com/\(i)",
                title: "Page \(i)",
                extractedText: String(repeating: "B", count: 3000)
            )
        }

        let result = self.sanitizer.sanitize(pages: pages)

        // Total extracted text should not exceed 8000 chars
        let totalContentChars = result.reduce(0) { total, page in
            let content = page.sanitizedText
                .replacingOccurrences(of: "[BEGIN FETCHED CONTENT FROM \(page.url)]\n", with: "")
                .replacingOccurrences(of: "\n[END FETCHED CONTENT]", with: "")
            return total + content.count
        }

        XCTAssertLessThanOrEqual(totalContentChars, SummaryContentSanitizer.maxTotalChars)
    }

    // MARK: - Delimiters

    func test_sanitizer_wrapsContentInDelimiters() {
        let pages = [SanitizablePageInput(
            url: "https://example.com/page",
            title: "Test Page",
            extractedText: "Some content here"
        )]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].sanitizedText.hasPrefix("[BEGIN FETCHED CONTENT FROM https://example.com/page]"))
        XCTAssertTrue(result[0].sanitizedText.hasSuffix("[END FETCHED CONTENT]"))
    }

    // MARK: - Unicode Invisible Characters

    func test_sanitizer_stripsUnicodeInvisibleCharacters() {
        // Zero-width space (U+200B), zero-width joiner (U+200D), RTL override (U+202E), BOM (U+FEFF)
        let invisible = "\u{200B}\u{200D}\u{202E}\u{FEFF}"
        let input = "Hello\(invisible)World"
        let pages = [SanitizablePageInput(
            url: "https://example.com",
            title: "Test",
            extractedText: input
        )]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].sanitizedText.contains("HelloWorld"))
        XCTAssertFalse(result[0].sanitizedText.contains("\u{200B}"))
        XCTAssertFalse(result[0].sanitizedText.contains("\u{200D}"))
        XCTAssertFalse(result[0].sanitizedText.contains("\u{202E}"))
        XCTAssertFalse(result[0].sanitizedText.contains("\u{FEFF}"))
    }

    // MARK: - Empty Input

    func test_sanitizer_skipsEmptyPages() {
        let pages = [
            SanitizablePageInput(url: "https://example.com/1", title: "Empty", extractedText: ""),
            SanitizablePageInput(url: "https://example.com/2", title: "Non-empty", extractedText: "Content")
        ]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].url, "https://example.com/2")
    }

    // MARK: - Preserves Newlines and Tabs

    func test_sanitizer_preservesNewlinesAndTabs() {
        let pages = [SanitizablePageInput(
            url: "https://example.com",
            title: "Test",
            extractedText: "Line1\nLine2\tTabbed"
        )]

        let result = self.sanitizer.sanitize(pages: pages)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].sanitizedText.contains("Line1\nLine2"))
    }
}
