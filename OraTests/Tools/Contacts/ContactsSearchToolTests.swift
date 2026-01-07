//
//  ContactsSearchToolTests.swift
//  OraTests
//
//  Tests for Contacts Search Tool
//

import XCTest
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
}
