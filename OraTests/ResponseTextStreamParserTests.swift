//
//  ResponseTextStreamParserTests.swift
//  OraTests
//
//  Tests for ResponseTextStreamParser
//

import XCTest
@testable import Ora

final class ResponseTextStreamParserTests: XCTestCase {

    func test_parserDecodesSurrogatePairs() {
        var parser = ResponseTextStreamParser()
        let fragments = [
            "{\"type\":\"response\",\"text\":\"Hello ",
            "\\uD83D",
            "\\uDE00\"}"
        ]

        var output = ""
        for fragment in fragments {
            output.append(contentsOf: parser.append(fragment))
        }

        let expected = "Hello " + String(UnicodeScalar(0x1F600)!)
        XCTAssertEqual(output, expected)
    }
}
