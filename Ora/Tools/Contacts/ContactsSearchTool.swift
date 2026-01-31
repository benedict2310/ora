//
//  ContactsSearchTool.swift
//  Ora
//
//  Search contacts by name with fuzzy fallback for ASR errors.
//

import Foundation
import Contacts

struct ContactsSearchTool: Tool {
    let name = "contacts.search"
    let kind: ToolKind = .read

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search contacts by name. Uses fuzzy matching when exact search finds no results.",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Name to search for", format: nil),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 10)", format: nil)
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        // Check permissions
        let status = await PermissionsManager.shared.request(.contacts)
        guard status == .authorized else {
            throw ContactsToolError.permissionDenied
        }

        let store = CNContactStore()

        guard let query = args["query"]?.stringValue else {
            throw ContactsToolError.invalidArgument("Query required")
        }

        let limit = Int(args["limit"]?.numberValue ?? 10)

        // 1. Try Apple's built-in name predicate first (fast, indexed)
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let exactContacts = try store.unifiedContacts(
            matching: predicate,
            keysToFetch: FuzzyContactMatcher.keysToFetch
        )

        if !exactContacts.isEmpty {
            let limited = Array(exactContacts.prefix(limit))
            let contactData: [JSONValue] = limited.map { Self.contactToJSON($0) }
            let summary = Self.summary(for: limited, query: query)
            return .success(.array(contactData), summary: summary)
        }

        // 2. Fallback: fuzzy match across all contacts (handles ASR spelling errors)
        let fuzzyMatches = try FuzzyContactMatcher.fuzzySearch(
            query: query,
            store: store,
            limit: limit
        )

        if fuzzyMatches.isEmpty {
            return .success(.array([]), summary: "No contacts found matching '\(query)'.")
        }

        let contactData: [JSONValue] = fuzzyMatches.map { scored in
            Self.contactToJSON(scored.contact, matchScore: scored.score)
        }
        let summary = Self.fuzzySummary(for: fuzzyMatches, query: query)
        return .success(.array(contactData), summary: summary)
    }

    // MARK: - Helpers

    static func contactToJSON(_ contact: CNContact, matchScore: Double? = nil) -> JSONValue {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let emails = contact.emailAddresses.map { $0.value as String }
        let phones = contact.phoneNumbers.map { $0.value.stringValue }

        var dict: [String: JSONValue] = [
            "name": .string(name),
            "organization": .string(contact.organizationName),
            "emails": .array(emails.map { .string($0) }),
            "phones": .array(phones.map { .string($0) })
        ]

        let nickname = contact.nickname
        if !nickname.isEmpty {
            dict["nickname"] = .string(nickname)
        }

        if let score = matchScore {
            dict["match_score"] = .number(Double(Int(score * 100)) / 100.0)
        }

        return .object(dict)
    }

    static func summary(for contacts: [CNContact], query: String) -> String {
        if contacts.isEmpty {
            return "No contacts found matching '\(query)'."
        } else if contacts.count == 1 {
            let contact = contacts[0]
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            // Try to find a phone or email for the summary
            if let phone = contact.phoneNumbers.first?.value.stringValue {
                return "\(name)'s phone number is \(phone)."
            } else if let email = contact.emailAddresses.first?.value as String? {
                return "\(name)'s email is \(email)."
            } else {
                return "Found \(name)."
            }
        } else {
            return "Found \(contacts.count) contacts matching '\(query)'."
        }
    }

    static func fuzzySummary(for matches: [ScoredContact], query: String) -> String {
        if matches.isEmpty {
            return "No contacts found matching '\(query)'."
        } else if matches.count == 1 {
            let contact = matches[0].contact
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "Found possible match: \(name) (fuzzy match for '\(query)')."
        } else {
            let names = matches.prefix(3).map { scored in
                [scored.contact.givenName, scored.contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            return "Found \(matches.count) possible matches for '\(query)': \(names.joined(separator: ", "))."
        }
    }
}
