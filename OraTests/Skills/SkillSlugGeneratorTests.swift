//
//  SkillSlugGeneratorTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillSlugGeneratorTests: XCTestCase {

    func test_slug_normalizesWhitespaceAndCasing() throws {
        let slug = try SkillSlugGenerator.slug(from: "  Monday Planning Routine  ")
        XCTAssertEqual(slug, "monday-planning-routine")
    }

    func test_slug_transliteratesUnicodeAndStripsSymbols() throws {
        let slug = try SkillSlugGenerator.slug(from: "Café résumé!!!")
        XCTAssertEqual(slug, "cafe-resume")
    }

    func test_slug_truncatesToFortyCharacters() throws {
        let slug = try SkillSlugGenerator.slug(from: "A Very Long Skill Name That Should Definitely Be Trimmed Down")
        XCTAssertLessThanOrEqual(slug.count, SkillSlugGenerator.maxLength)
        XCTAssertEqual(slug, "a-very-long-skill-name-that-should-defin")
    }

    func test_slug_emptyName_throwsError() {
        XCTAssertThrowsError(try SkillSlugGenerator.slug(from: "   ")) { error in
            XCTAssertEqual(error as? SkillError, .invalidName)
        }
    }

    func test_resolveUniqueSlug_existingAgentCollision_appendsSuffix() throws {
        let slug = try SkillSlugGenerator.resolveUniqueSlug(
            from: "Monday Planning Routine",
            existingAgentIDs: ["monday-planning-routine"],
            blockedIDs: [:]
        )

        XCTAssertEqual(slug, "monday-planning-routine-2")
    }

    func test_resolveUniqueSlug_allSuffixesTaken_throwsError() {
        let existingAgentIDs: Set<String> = [
            "monday-planning-routine",
            "monday-planning-routine-2",
            "monday-planning-routine-3",
            "monday-planning-routine-4",
            "monday-planning-routine-5",
            "monday-planning-routine-6",
            "monday-planning-routine-7",
            "monday-planning-routine-8",
            "monday-planning-routine-9"
        ]

        XCTAssertThrowsError(
            try SkillSlugGenerator.resolveUniqueSlug(
                from: "Monday Planning Routine",
                existingAgentIDs: existingAgentIDs,
                blockedIDs: [:]
            )
        ) { error in
            XCTAssertEqual(error as? SkillError, .slugExhausted("monday-planning-routine"))
        }
    }
}
