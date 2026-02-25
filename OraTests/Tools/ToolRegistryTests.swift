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

    func test_toolLoadPolicy_defaultsToDeferred() {
        let tool = MockReadTool()
        XCTAssertEqual(tool.loadPolicy, .deferred)
    }
    
    func test_registerDefaultToolsIfNeeded_registersOnFirstCall() async {
        // Ensure registry is empty
        await ToolRegistry.shared.clear()
        
        let registered = await ToolRegistry.shared.registerDefaultToolsIfNeeded()
        XCTAssertTrue(registered, "Should return true on first call")
        
        let tools = await ToolRegistry.shared.allTools()
        XCTAssertGreaterThan(tools.count, 0, "Should have registered tools")
        
        // Cleanup
        await ToolRegistry.shared.clear()
    }
    
    func test_registerDefaultToolsIfNeeded_isIdempotent() async {
        // Ensure registry is empty
        await ToolRegistry.shared.clear()
        
        // First call registers tools
        let firstCall = await ToolRegistry.shared.registerDefaultToolsIfNeeded()
        XCTAssertTrue(firstCall, "First call should return true")
        
        let countAfterFirst = await ToolRegistry.shared.allTools().count
        
        // Second call should not register again
        let secondCall = await ToolRegistry.shared.registerDefaultToolsIfNeeded()
        XCTAssertFalse(secondCall, "Second call should return false (already registered)")
        
        let countAfterSecond = await ToolRegistry.shared.allTools().count
        XCTAssertEqual(countAfterFirst, countAfterSecond, "Tool count should not change")
        
        // Cleanup
        await ToolRegistry.shared.clear()
    }

    func test_coreTools_areExactExpectedSet() async {
        await ToolRegistry.shared.registerDefaultTools()

        let names = await ToolRegistry.shared.coreSchemas().map(\.name)

        XCTAssertEqual(
            Set(names),
            Set([
                "calendar.query",
                "contacts.search",
                "reminders.list",
                "system.open_app",
                "mail.recent",
                "tools.discover"
            ])
        )
    }

    func test_deferredCatalog_excludesCoreTools() async {
        await ToolRegistry.shared.registerDefaultTools()

        let deferred = await ToolRegistry.shared.deferredCatalogRows()
        let deferredNames = Set(deferred.map(\.name))

        XCTAssertFalse(deferredNames.contains("calendar.query"))
        XCTAssertFalse(deferredNames.contains("tools.discover"))
        XCTAssertTrue(deferredNames.contains("messages.send"))
        XCTAssertTrue(deferredNames.contains("system.search_files"))
    }

    func test_discoveryIndex_containsDeferredToolsOnly() async {
        await ToolRegistry.shared.registerDefaultTools()

        let indexedNames = Set(await ToolRegistry.shared.discoveryIndexedToolNames())

        XCTAssertFalse(indexedNames.contains("calendar.query"))
        XCTAssertFalse(indexedNames.contains("tools.discover"))
        XCTAssertTrue(indexedNames.contains("messages.send"))
        XCTAssertTrue(indexedNames.contains("system.search_files"))
    }

    func test_discoverTools_cachesDiscoveredNamesPerSession() async {
        await ToolRegistry.shared.registerDefaultTools()

        let sessionID = UUID()
        _ = await ToolRegistry.shared.discoverTools(query: "send a message", limit: 3, sessionID: sessionID)
        _ = await ToolRegistry.shared.discoverTools(query: "search my files", limit: 3, sessionID: sessionID)

        let discoveredNames = await ToolRegistry.shared.discoveredToolNames(for: sessionID)

        XCTAssertTrue(discoveredNames.contains("messages.send"))
        XCTAssertTrue(discoveredNames.contains("system.search_files"))
    }

    func test_discoveredSchemas_returnsSchemasForSession() async {
        await ToolRegistry.shared.registerDefaultTools()

        let sessionID = UUID()
        _ = await ToolRegistry.shared.discoverTools(query: "send a message", limit: 3, sessionID: sessionID)

        let discovered = await ToolRegistry.shared.discoveredSchemas(for: sessionID).map(\.name)
        XCTAssertTrue(discovered.contains("messages.send"))
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
