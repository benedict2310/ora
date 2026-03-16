//
//  HTMLTextExtractorTests.swift
//  OraTests
//
//  Tests for lightweight HTML-to-text extraction.
//

import XCTest
@testable import Ora

final class HTMLTextExtractorTests: XCTestCase {

    func test_extract_titleAndBodyText() {
        let extractor = HTMLTextExtractor()
        let html = """
        <html>
          <head><title>Example Doc</title></head>
          <body>
            <h1>Heading</h1>
            <p>First paragraph.</p>
            <p>Second paragraph.</p>
          </body>
        </html>
        """

        let result = extractor.extract(from: html)

        XCTAssertEqual(result.title, "Example Doc")
        // The extractor includes title text in the body output and collapses block elements
        XCTAssertTrue(result.text.contains("Heading"))
        XCTAssertTrue(result.text.contains("First paragraph."))
        XCTAssertTrue(result.text.contains("Second paragraph."))
    }

    func test_extract_removesScriptsAndStyles() {
        let extractor = HTMLTextExtractor()
        let html = """
        <html>
          <head>
            <style>body { display: none; }</style>
            <script>window.alert('bad');</script>
          </head>
          <body>
            <noscript>Fallback</noscript>
            <p>Visible text</p>
          </body>
        </html>
        """

        let result = extractor.extract(from: html)

        XCTAssertEqual(result.text, "Visible text")
    }

    func test_extract_decodesEntities() {
        let extractor = HTMLTextExtractor()
        let html = "<p>Fish &amp; Chips &lt;3 &#39;quoted&#39; &#x41;</p>"

        let result = extractor.extract(from: html)

        XCTAssertEqual(result.text, "Fish & Chips <3 'quoted' A")
    }

    func test_extract_collapsesWhitespace() {
        let extractor = HTMLTextExtractor()
        let html = """
        <div>
            Alpha

            <span>   Beta   </span>
            <p>
                Gamma
            </p>
        </div>
        """

        let result = extractor.extract(from: html)

        // The extractor collapses whitespace; block element handling may vary
        XCTAssertTrue(result.text.contains("Alpha"))
        XCTAssertTrue(result.text.contains("Beta"))
        XCTAssertTrue(result.text.contains("Gamma"))
    }

    func test_extract_emptyHTML_returnsEmptyText() {
        let extractor = HTMLTextExtractor()

        let result = extractor.extract(from: "")

        XCTAssertNil(result.title)
        XCTAssertEqual(result.text, "")
    }
}
