//
//  FuzzyContactMatcherTests.swift
//  OraTests
//
//  Tests for StringSimilarity and FuzzyContactMatcher
//

import XCTest
import Contacts
@testable import Ora

// MARK: - StringSimilarity Tests

final class StringSimilarityTests: XCTestCase {

    // MARK: - Jaro Tests

    func test_jaro_identicalStrings() {
        XCTAssertEqual(StringSimilarity.jaro("hello", "hello"), 1.0, accuracy: 0.001)
    }

    func test_jaro_completelyDifferent() {
        let score = StringSimilarity.jaro("abc", "xyz")
        XCTAssertLessThan(score, 0.5)
    }

    func test_jaro_emptyStrings() {
        XCTAssertEqual(StringSimilarity.jaro("", ""), 1.0)
        XCTAssertEqual(StringSimilarity.jaro("hello", ""), 0.0)
        XCTAssertEqual(StringSimilarity.jaro("", "hello"), 0.0)
    }

    func test_jaro_singleCharacterMatch() {
        XCTAssertEqual(StringSimilarity.jaro("a", "a"), 1.0)
    }

    func test_jaro_singleCharacterMismatch() {
        XCTAssertEqual(StringSimilarity.jaro("a", "b"), 0.0)
    }

    func test_jaro_transposition() {
        // "martha" vs "marhta" - characters match with transpositions
        let score = StringSimilarity.jaro("martha", "marhta")
        XCTAssertGreaterThan(score, 0.9)
        XCTAssertLessThan(score, 1.0)
    }

    func test_jaro_caseInsensitive() {
        XCTAssertEqual(
            StringSimilarity.jaro("Hello", "hello"),
            1.0,
            accuracy: 0.001
        )
    }

    // MARK: - Jaro-Winkler Tests

    func test_jaroWinkler_identicalStrings() {
        XCTAssertEqual(StringSimilarity.jaroWinkler("hello", "hello"), 1.0, accuracy: 0.001)
    }

    func test_jaroWinkler_commonPrefix_boostsScore() {
        // Strings sharing a prefix should score higher with Winkler than plain Jaro
        let jaro = StringSimilarity.jaro("Madeline", "Madeleine")
        let winkler = StringSimilarity.jaroWinkler("Madeline", "Madeleine")
        XCTAssertGreaterThanOrEqual(winkler, jaro)
    }

    func test_jaroWinkler_madelineMadeleine() {
        // Core ASR scenario: "Madeline" vs "Madeleine"
        let score = StringSimilarity.jaroWinkler("Madeline", "Madeleine")
        XCTAssertGreaterThan(score, 0.9, "Madeline/Madeleine should be highly similar")
    }

    func test_jaroWinkler_stephenSteven() {
        // Another common ASR variant
        let score = StringSimilarity.jaroWinkler("Stephen", "Steven")
        XCTAssertGreaterThan(score, 0.85)
    }

    func test_jaroWinkler_johnJon() {
        let score = StringSimilarity.jaroWinkler("John", "Jon")
        XCTAssertGreaterThan(score, 0.85)
    }

    func test_jaroWinkler_caseInsensitive() {
        XCTAssertEqual(
            StringSimilarity.jaroWinkler("ALICE", "alice"),
            1.0,
            accuracy: 0.001
        )
    }

    func test_jaroWinkler_emptyStrings() {
        XCTAssertEqual(StringSimilarity.jaroWinkler("", ""), 1.0)
        XCTAssertEqual(StringSimilarity.jaroWinkler("test", ""), 0.0)
    }

    func test_jaroWinkler_noCommonPrefix_sameAsJaro() {
        // When strings share no prefix, Winkler adds no bonus
        let jaro = StringSimilarity.jaro("xyz", "abc")
        let winkler = StringSimilarity.jaroWinkler("xyz", "abc")
        XCTAssertEqual(jaro, winkler, accuracy: 0.001)
    }

    // MARK: - bestScore Tests

    func test_bestScore_returnsMaximum() {
        let score = StringSimilarity.bestScore(
            query: "Alice",
            candidates: ["Bob", "Alicia", "Alice", "Charlie"]
        )
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func test_bestScore_emptyCandidates() {
        XCTAssertEqual(StringSimilarity.bestScore(query: "test", candidates: []), 0.0)
    }
}

// MARK: - FuzzyContactMatcher Tests

final class FuzzyContactMatcherTests: XCTestCase {

    // MARK: - Scoring Tests

    func test_score_exactGivenName() {
        let contact = Self.makeContact(given: "Alice", family: "Smith")
        let scored = FuzzyContactMatcher.score(query: "Alice", contact: contact)
        XCTAssertEqual(scored.score, 1.0, accuracy: 0.001)
        XCTAssertEqual(scored.matchField, .givenName)
    }

    func test_score_exactFullName() {
        let contact = Self.makeContact(given: "Alice", family: "Smith")
        let scored = FuzzyContactMatcher.score(query: "Alice Smith", contact: contact)
        XCTAssertEqual(scored.score, 1.0, accuracy: 0.001)
        XCTAssertEqual(scored.matchField, .fullName)
    }

    func test_score_fuzzyGivenName() {
        let contact = Self.makeContact(given: "Madeleine", family: "Jones")
        let scored = FuzzyContactMatcher.score(query: "Madeline", contact: contact)
        XCTAssertGreaterThan(scored.score, 0.9)
    }

    func test_score_nicknameMatch() {
        let contact = Self.makeContact(given: "Elizabeth", family: "Taylor", nickname: "Liz")
        let scored = FuzzyContactMatcher.score(query: "Liz", contact: contact)
        XCTAssertEqual(scored.score, 1.0, accuracy: 0.001)
        XCTAssertEqual(scored.matchField, .nickname)
    }

    func test_score_phoneticGivenMatch() {
        let contact = Self.makeContact(
            given: "Bjork",
            family: "Gudmundsdottir",
            phoneticGiven: "Byerk"
        )
        let scored = FuzzyContactMatcher.score(query: "Byerk", contact: contact)
        XCTAssertEqual(scored.score, 1.0, accuracy: 0.001)
        XCTAssertEqual(scored.matchField, .phoneticGiven)
    }

    func test_score_phoneticFamilyMatch() {
        let contact = Self.makeContact(
            given: "Wei",
            family: "Zhang",
            phoneticFamily: "Jang"
        )
        let scored = FuzzyContactMatcher.score(query: "Jang", contact: contact)
        XCTAssertEqual(scored.score, 1.0, accuracy: 0.001)
        XCTAssertEqual(scored.matchField, .phoneticFamily)
    }

    func test_score_bestFieldWins() {
        // Nickname "Mike" is an exact match; given "Michael" is only fuzzy
        let contact = Self.makeContact(given: "Michael", family: "Brown", nickname: "Mike")
        let scored = FuzzyContactMatcher.score(query: "Mike", contact: contact)
        XCTAssertEqual(scored.score, 1.0, accuracy: 0.001)
        XCTAssertEqual(scored.matchField, .nickname)
    }

    func test_score_emptyContact() {
        let contact = Self.makeContact(given: "", family: "")
        let scored = FuzzyContactMatcher.score(query: "Alice", contact: contact)
        XCTAssertEqual(scored.score, 0.0)
    }

    // MARK: - Matching Tests

    func test_match_rankedByScore() {
        let contacts = [
            Self.makeContact(given: "Bob", family: "Wilson"),
            Self.makeContact(given: "Madeleine", family: "Jones"),
            Self.makeContact(given: "Madeline", family: "Smith"),
        ]

        let results = FuzzyContactMatcher.match(
            query: "Madeline",
            in: contacts,
            threshold: 0.8
        )

        XCTAssertGreaterThanOrEqual(results.count, 1)
        // Exact match "Madeline" should rank first
        XCTAssertEqual(results[0].contact.familyName, "Smith")

        if results.count >= 2 {
            // "Madeleine" should also match as a close fuzzy match
            XCTAssertEqual(results[1].contact.familyName, "Jones")
            // Scores should be descending
            XCTAssertGreaterThanOrEqual(results[0].score, results[1].score)
        }
    }

    func test_match_thresholdFiltering() {
        let contacts = [
            Self.makeContact(given: "Alice", family: "Smith"),
            Self.makeContact(given: "Bob", family: "Wilson"),
        ]

        // Very high threshold should only match exact
        let strict = FuzzyContactMatcher.match(
            query: "Alice",
            in: contacts,
            threshold: 0.99
        )
        XCTAssertEqual(strict.count, 1)
        XCTAssertEqual(strict[0].contact.givenName, "Alice")

        // "Bob" should never match "Alice" at any reasonable threshold
        let noMatch = FuzzyContactMatcher.match(
            query: "Alice",
            in: contacts,
            threshold: 1.0
        )
        // Only exact match at 1.0
        XCTAssertEqual(noMatch.count, 1)
    }

    func test_match_respectsLimit() {
        let contacts = (0..<20).map { i in
            Self.makeContact(given: "Alice\(i)", family: "Smith")
        }

        let results = FuzzyContactMatcher.match(
            query: "Alice",
            in: contacts,
            threshold: 0.5,
            limit: 3
        )
        XCTAssertLessThanOrEqual(results.count, 3)
    }

    func test_match_emptyQuery() {
        let contacts = [Self.makeContact(given: "Alice", family: "Smith")]
        let results = FuzzyContactMatcher.match(query: "", in: contacts)
        XCTAssertTrue(results.isEmpty)
    }

    func test_match_whitespaceQuery() {
        let contacts = [Self.makeContact(given: "Alice", family: "Smith")]
        let results = FuzzyContactMatcher.match(query: "   ", in: contacts)
        XCTAssertTrue(results.isEmpty)
    }

    func test_match_emptyContacts() {
        let results = FuzzyContactMatcher.match(query: "Alice", in: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - ASR Error Scenarios

    func test_asrScenario_madelineMadeleine() {
        // ASR transcribes "Madeleine" as "Madeline"
        let contacts = [
            Self.makeContact(given: "Madeleine", family: "Jones"),
            Self.makeContact(given: "Bob", family: "Wilson"),
        ]

        let results = FuzzyContactMatcher.match(
            query: "Madeline",
            in: contacts,
            threshold: FuzzyContactMatcher.defaultThreshold
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].contact.givenName, "Madeleine")
        XCTAssertGreaterThan(results[0].score, 0.9)
    }

    func test_asrScenario_stephenSteven() {
        let contacts = [
            Self.makeContact(given: "Stephen", family: "King"),
            Self.makeContact(given: "Alice", family: "Smith"),
        ]

        let results = FuzzyContactMatcher.match(
            query: "Steven",
            in: contacts,
            threshold: FuzzyContactMatcher.defaultThreshold
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].contact.givenName, "Stephen")
    }

    func test_asrScenario_nicknameFallback() {
        // Contact is "Elizabeth" but user says "Liz"
        let contacts = [
            Self.makeContact(given: "Elizabeth", family: "Taylor", nickname: "Liz"),
            Self.makeContact(given: "Lisa", family: "Brown"),
        ]

        let results = FuzzyContactMatcher.match(
            query: "Liz",
            in: contacts,
            threshold: 0.8
        )

        // "Liz" should match the nickname
        let hasElizabeth = results.contains { $0.contact.givenName == "Elizabeth" }
        XCTAssertTrue(hasElizabeth, "Should match Elizabeth via nickname 'Liz'")
    }

    func test_asrScenario_phoneticName() {
        // User says a phonetic approximation
        let contacts = [
            Self.makeContact(
                given: "Bjork",
                family: "Gudmundsdottir",
                phoneticGiven: "Byerk"
            ),
        ]

        let results = FuzzyContactMatcher.match(
            query: "Byerk",
            in: contacts,
            threshold: 0.8
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].contact.givenName, "Bjork")
    }

    // MARK: - Helpers

    private static func makeContact(
        given: String,
        family: String,
        nickname: String = "",
        phoneticGiven: String = "",
        phoneticFamily: String = ""
    ) -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = given
        contact.familyName = family
        contact.nickname = nickname
        contact.phoneticGivenName = phoneticGiven
        contact.phoneticFamilyName = phoneticFamily
        return contact
    }
}
