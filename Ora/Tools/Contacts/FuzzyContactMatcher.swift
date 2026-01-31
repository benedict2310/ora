//
//  FuzzyContactMatcher.swift
//  Ora
//
//  Fuzzy contact matching using Jaro-Winkler similarity with
//  phonetic name and nickname support.
//

@preconcurrency import Contacts
import Foundation

struct ScoredContact: Sendable {
    let contact: CNContact
    let score: Double
    let matchField: MatchField

    enum MatchField: String, Sendable {
        case givenName
        case familyName
        case fullName
        case nickname
        case phoneticGiven
        case phoneticFamily
        case phoneticFull
    }
}

enum FuzzyContactMatcher {

    /// Minimum Jaro-Winkler score to consider a contact a potential match.
    static let defaultThreshold: Double = 0.82

    /// Keys required for fuzzy matching (superset of basic search keys).
    static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as NSString,
        CNContactFamilyNameKey as NSString,
        CNContactPhoneticGivenNameKey as NSString,
        CNContactPhoneticFamilyNameKey as NSString,
        CNContactNicknameKey as NSString,
        CNContactEmailAddressesKey as NSString,
        CNContactPhoneNumbersKey as NSString,
        CNContactOrganizationNameKey as NSString
    ]

    /// Score a single contact against a query.
    ///
    /// Compares the query against given name, family name, full name,
    /// nickname, and phonetic variants. Returns the best-scoring field.
    static func score(query: String, contact: CNContact) -> ScoredContact {
        let given = contact.givenName
        let family = contact.familyName
        let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        let nickname = contact.nickname
        let phoneticGiven = contact.phoneticGivenName
        let phoneticFamily = contact.phoneticFamilyName
        let phoneticFull = [phoneticGiven, phoneticFamily]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var bestScore = 0.0
        var bestField = ScoredContact.MatchField.fullName

        let candidates: [(String, ScoredContact.MatchField)] = [
            (given, .givenName),
            (family, .familyName),
            (full, .fullName),
            (nickname, .nickname),
            (phoneticGiven, .phoneticGiven),
            (phoneticFamily, .phoneticFamily),
            (phoneticFull, .phoneticFull),
        ]

        for (value, field) in candidates where !value.isEmpty {
            let s = StringSimilarity.jaroWinkler(query, value)
            if s > bestScore {
                bestScore = s
                bestField = field
            }
        }

        return ScoredContact(contact: contact, score: bestScore, matchField: bestField)
    }

    /// Find contacts that fuzzy-match a query, ranked by score.
    ///
    /// - Parameters:
    ///   - query: The name to search for (e.g. from ASR transcription).
    ///   - contacts: Contacts to match against (must have `keysToFetch` loaded).
    ///   - threshold: Minimum Jaro-Winkler score (default 0.82).
    ///   - limit: Maximum results to return.
    /// - Returns: Contacts sorted by descending score, filtered above threshold.
    static func match(
        query: String,
        in contacts: [CNContact],
        threshold: Double = defaultThreshold,
        limit: Int = 5
    ) -> [ScoredContact] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        return contacts
            .map { score(query: query, contact: $0) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Fetch all contacts from the store and run fuzzy matching.
    ///
    /// Use this as a fallback when `CNContact.predicateForContacts(matchingName:)`
    /// returns no results (common with ASR transcription errors).
    static func fuzzySearch(
        query: String,
        store: CNContactStore,
        threshold: Double = defaultThreshold,
        limit: Int = 5
    ) throws -> [ScoredContact] {
        var allContacts: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .givenName

        try store.enumerateContacts(with: request) { contact, _ in
            allContacts.append(contact)
        }

        return match(query: query, in: allContacts, threshold: threshold, limit: limit)
    }
}
