//
//  SkillFrontmatterParserTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillFrontmatterParserTests: XCTestCase {

    func test_parse_validFrontmatter_returnsNameDescriptionAndVersion() throws {
        let markdown = """
        ---
        name: Daily Briefing
        description: Summarize my day
        version: 1.2.0
        ---

        Body
        """

        let frontmatter = try SkillFrontmatterParser.parse(from: markdown)
        XCTAssertEqual(frontmatter.name, "Daily Briefing")
        XCTAssertEqual(frontmatter.description, "Summarize my day")
        XCTAssertEqual(frontmatter.version, "1.2.0")
    }

    func test_parse_missingName_throwsInvalidFrontmatter() {
        let markdown = """
        ---
        description: Summarize my day
        ---
        """

        XCTAssertThrowsError(try SkillFrontmatterParser.parse(from: markdown)) { error in
            guard case SkillError.invalidFrontmatter(let reason) = error else {
                return XCTFail("Expected invalidFrontmatter")
            }
            XCTAssertTrue(reason.contains("name"))
        }
    }

    func test_parse_missingDescription_throwsInvalidFrontmatter() {
        let markdown = """
        ---
        name: Daily Briefing
        ---
        """

        XCTAssertThrowsError(try SkillFrontmatterParser.parse(from: markdown)) { error in
            guard case SkillError.invalidFrontmatter(let reason) = error else {
                return XCTFail("Expected invalidFrontmatter")
            }
            XCTAssertTrue(reason.contains("description"))
        }
    }

    func test_parse_frontmatterWithQuotes_unquotesValues() throws {
        let markdown = """
        ---
        name: "Daily Briefing"
        description: 'Summarize my day'
        ---
        """

        let frontmatter = try SkillFrontmatterParser.parse(from: markdown)
        XCTAssertEqual(frontmatter.name, "Daily Briefing")
        XCTAssertEqual(frontmatter.description, "Summarize my day")
    }

    func test_parse_missingFence_throwsInvalidFrontmatter() {
        let markdown = """
        name: Daily Briefing
        description: Summarize my day
        """

        XCTAssertThrowsError(try SkillFrontmatterParser.parse(from: markdown)) { error in
            guard case SkillError.invalidFrontmatter(let reason) = error else {
                return XCTFail("Expected invalidFrontmatter")
            }
            XCTAssertTrue(reason.contains("Missing YAML frontmatter"))
        }
    }
}
