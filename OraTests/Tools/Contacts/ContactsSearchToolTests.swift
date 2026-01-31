//
//  ContactsSearchToolTests.swift
//  OraTests
//
//  Tests for Contacts Search Tool
//

import XCTest
import Contacts
@testable import Ora

final class ContactsSearchToolTests: XCTestCase {
    
    // MARK: - Validation Tests
    
    func test_validate_success() throws {
        let tool = ContactsSearchTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "query": .string("John"),
            "limit": .number(5)
        ]))
    }
    
    func test_validate_missingQuery() {
        let tool = ContactsSearchTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "limit": .number(5)
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_validate_emptyQuery() {
        let tool = ContactsSearchTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "query": .string(""),
            "limit": .number(5)
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    // MARK: - Schema Tests
    
    func test_schema() {
        let tool = ContactsSearchTool()
        XCTAssertEqual(tool.name, "contacts.search")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["query"])
        
        let params = tool.schema.parameters
        XCTAssertNotNil(params["query"])
        XCTAssertNotNil(params["limit"])
    }
    
    // MARK: - Registration Test
    
    func test_toolRegistration() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()
        
        let tool = await ToolRegistry.shared.tool(named: "contacts.search")
        XCTAssertNotNil(tool)
        XCTAssertTrue(tool is ContactsSearchTool)
    }

    // MARK: - Logic Tests
    
    func test_contactToJSON_formatsCorrectly() {
        let contact = CNMutableContact()
        contact.givenName = "John"
        contact.familyName = "Doe"
        contact.organizationName = "Acme Corp"
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "john@example.com" as NSString)]
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "555-1234"))]
        
        let json = ContactsSearchTool.contactToJSON(contact)
        
        guard case .object(let dict) = json else {
            XCTFail("Expected object")
            return
        }
        
        XCTAssertEqual(dict["name"]?.stringValue, "John Doe")
        XCTAssertEqual(dict["organization"]?.stringValue, "Acme Corp")
        
        guard case .array(let emails)? = dict["emails"] else {
            XCTFail("Expected emails array")
            return
        }
        XCTAssertEqual(emails.first?.stringValue, "john@example.com")
        
        guard case .array(let phones)? = dict["phones"] else {
            XCTFail("Expected phones array")
            return
        }
        XCTAssertEqual(phones.first?.stringValue, "555-1234")
    }
    
    func test_summary_empty() {
        let summary = ContactsSearchTool.summary(for: [], query: "John")
        XCTAssertEqual(summary, "No contacts found matching 'John'.")
    }
    
    func test_summary_singleWithPhone() {
        let contact = CNMutableContact()
        contact.givenName = "John"
        contact.familyName = "Doe"
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "555-1234"))]
        
        let summary = ContactsSearchTool.summary(for: [contact], query: "John")
        XCTAssertEqual(summary, "John Doe's phone number is 555-1234.")
    }
    
    func test_summary_singleWithEmail() {
        let contact = CNMutableContact()
        contact.givenName = "John"
        contact.familyName = "Doe"
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "john@example.com" as NSString)]
        
        let summary = ContactsSearchTool.summary(for: [contact], query: "John")
        XCTAssertEqual(summary, "John Doe's email is john@example.com.")
    }
    
    func test_summary_singleWithNameOnly() {
        let contact = CNMutableContact()
        contact.givenName = "John"
        contact.familyName = "Doe"
        
        let summary = ContactsSearchTool.summary(for: [contact], query: "John")
        XCTAssertEqual(summary, "Found John Doe.")
    }
    
    func test_summary_multiple() {
        let contact1 = CNMutableContact()
        contact1.givenName = "John"

        let contact2 = CNMutableContact()
        contact2.givenName = "Jane"

        let summary = ContactsSearchTool.summary(for: [contact1, contact2], query: "J")
        XCTAssertEqual(summary, "Found 2 contacts matching 'J'.")
    }

    // MARK: - Nickname in JSON

    func test_contactToJSON_includesNickname() {
        let contact = CNMutableContact()
        contact.givenName = "Elizabeth"
        contact.familyName = "Taylor"
        contact.nickname = "Liz"

        let json = ContactsSearchTool.contactToJSON(contact)

        guard case .object(let dict) = json else {
            XCTFail("Expected object")
            return
        }

        XCTAssertEqual(dict["nickname"]?.stringValue, "Liz")
    }

    func test_contactToJSON_omitsEmptyNickname() {
        let contact = CNMutableContact()
        contact.givenName = "John"
        contact.familyName = "Doe"

        let json = ContactsSearchTool.contactToJSON(contact)

        guard case .object(let dict) = json else {
            XCTFail("Expected object")
            return
        }

        XCTAssertNil(dict["nickname"])
    }

    // MARK: - Match Score in JSON

    func test_contactToJSON_includesMatchScore() throws {
        let contact = CNMutableContact()
        contact.givenName = "Alice"
        contact.familyName = "Smith"

        let json = ContactsSearchTool.contactToJSON(contact, matchScore: 0.95)

        guard case .object(let dict) = json else {
            XCTFail("Expected object")
            return
        }

        let score = try XCTUnwrap(dict["match_score"]?.numberValue)
        XCTAssertEqual(score, 0.95, accuracy: 0.01)
    }

    func test_contactToJSON_omitsMatchScoreWhenNil() {
        let contact = CNMutableContact()
        contact.givenName = "Alice"

        let json = ContactsSearchTool.contactToJSON(contact)

        guard case .object(let dict) = json else {
            XCTFail("Expected object")
            return
        }

        XCTAssertNil(dict["match_score"])
    }

    // MARK: - Fuzzy Summary Tests

    func test_fuzzySummary_empty() {
        let summary = ContactsSearchTool.fuzzySummary(for: [], query: "Madline")
        XCTAssertEqual(summary, "No contacts found matching 'Madline'.")
    }

    func test_fuzzySummary_singleMatch() {
        let contact = CNMutableContact()
        contact.givenName = "Madeline"
        contact.familyName = "Smith"
        let scored = ScoredContact(contact: contact, score: 0.95, matchField: .givenName)

        let summary = ContactsSearchTool.fuzzySummary(for: [scored], query: "Madline")
        XCTAssertEqual(summary, "Found possible match: Madeline Smith (fuzzy match for 'Madline').")
    }

    func test_fuzzySummary_multipleMatches() {
        let c1 = CNMutableContact()
        c1.givenName = "Madeline"
        c1.familyName = "Smith"
        let c2 = CNMutableContact()
        c2.givenName = "Madeleine"
        c2.familyName = "Jones"

        let matches = [
            ScoredContact(contact: c1, score: 0.97, matchField: .givenName),
            ScoredContact(contact: c2, score: 0.93, matchField: .givenName),
        ]

        let summary = ContactsSearchTool.fuzzySummary(for: matches, query: "Madline")
        XCTAssertTrue(summary.contains("2 possible matches"))
        XCTAssertTrue(summary.contains("Madeline Smith"))
        XCTAssertTrue(summary.contains("Madeleine Jones"))
    }
}
