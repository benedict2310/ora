//
//  ToolRegistryTests.swift
//  OraTests
//
//  Tests for ToolRegistry
//

import XCTest
@testable import Ora

final class ToolRegistryTests: XCTestCase {
    
    override func setUp() async throws {
        await ToolRegistry.shared.clear()
    }
    
    func test_registerAndRetrieveTool() async {
        let tool = MockReadTool()
        await ToolRegistry.shared.register(tool)
        
        let retrieved = await ToolRegistry.shared.tool(named: "mock.read")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "mock.read")
    }
    
    func test_allTools() async {
        let tool1 = MockReadTool()
        let tool2 = MockMutateTool()
        
        await ToolRegistry.shared.register(tool1)
        await ToolRegistry.shared.register(tool2)
        
        let all = await ToolRegistry.shared.allTools()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.name == "mock.read" })
        XCTAssertTrue(all.contains { $0.name == "mock.mutate" })
    }
    
    func test_schemas() async {
        let tool = MockReadTool()
        await ToolRegistry.shared.register(tool)
        
        let schemas = await ToolRegistry.shared.schemas()
        XCTAssertEqual(schemas.count, 1)
        XCTAssertEqual(schemas.first?.name, "mock.read")
    }
}

// MARK: - Mock Tools

struct MockReadTool: Tool {
    let name = "mock.read"
    let kind: ToolKind = .read
    let schema = ToolSchema(
        name: "mock.read",
        description: "A read tool",
        parameters: [:],
        requiredParameters: [],
        requiresConfirmation: false
    )
    
    func validate(args: [String: JSONValue]) throws {}
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        return .success(.string("read"), summary: "Read success")
    }
}

struct MockMutateTool: Tool {
    let name = "mock.mutate"
    let kind: ToolKind = .mutate
    let schema = ToolSchema(
        name: "mock.mutate",
        description: "A mutate tool",
        parameters: [:],
        requiredParameters: [],
        requiresConfirmation: true
    )
    
    func validate(args: [String: JSONValue]) throws {}
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        return .success(.string("mutated"), summary: "Mutate success")
    }
}
