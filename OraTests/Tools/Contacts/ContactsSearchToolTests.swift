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
}
