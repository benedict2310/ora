//
//  ToolDiscoveryTests.swift
//  OraTests
//
//  Focused tests for dynamic tool discovery mechanics.
//

import XCTest
@testable import Ora

final class ToolDiscoveryTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()
    }

    override func tearDown() async throws {
        await ToolRegistry.shared.clear()
    }

    func test_discoveryIndex_buildsForDeferredTools() async {
        let indexedNames = Set(await ToolRegistry.shared.discoveryIndexedToolNames())

        XCTAssertFalse(indexedNames.contains("tools.discover"))
        XCTAssertFalse(indexedNames.contains("calendar.query"))
        XCTAssertTrue(indexedNames.contains("messages.send"))
        XCTAssertTrue(indexedNames.contains("system.search_files"))
    }

    func test_toolsDiscover_sendMessageQuery_includesMessagesSendInTop3() async throws {
        let tool = ToolDiscoveryTool()
        let sessionID = UUID()

        let result = try await tool.execute(
            args: [
                "query": .string("send a message"),
                "limit": .number(3),
                ToolDiscoveryTool.sessionIDArgumentKey: .string(sessionID.uuidString)
            ]
        )

        let names = self.extractMatchedToolNames(from: result)
        XCTAssertLessThanOrEqual(names.count, 3)
        XCTAssertTrue(names.contains("messages.send"))
    }

    func test_toolsDiscover_searchFilesQuery_includesSystemSearchFilesInTop3() async throws {
        let tool = ToolDiscoveryTool()
        let sessionID = UUID()

        let result = try await tool.execute(
            args: [
                "query": .string("search my files"),
                "limit": .number(3),
                ToolDiscoveryTool.sessionIDArgumentKey: .string(sessionID.uuidString)
            ]
        )

        let names = self.extractMatchedToolNames(from: result)
        XCTAssertLessThanOrEqual(names.count, 3)
        XCTAssertTrue(names.contains("system.search_files"))
    }

    func test_toolsDiscover_scriptQuery_includesSkillsRunScript() async throws {
        let tool = ToolDiscoveryTool()
        let sessionID = UUID()

        let result = try await tool.execute(
            args: [
                "query": .string("run a helper script from a skill"),
                "limit": .number(5),
                ToolDiscoveryTool.sessionIDArgumentKey: .string(sessionID.uuidString)
            ]
        )

        let names = self.extractMatchedToolNames(from: result)
        XCTAssertTrue(names.contains("skills.run_script"))
    }

    func test_toolsDiscover_blankQuery_failsValidation() {
        let tool = ToolDiscoveryTool()

        XCTAssertThrowsError(
            try tool.validate(args: ["query": .string("   ")])
        )
    }

    func test_toolsDiscover_sessionCache_accumulatesDiscoveredTools() async throws {
        let tool = ToolDiscoveryTool()
        let sessionID = UUID()

        _ = try await tool.execute(
            args: [
                "query": .string("send a message"),
                ToolDiscoveryTool.sessionIDArgumentKey: .string(sessionID.uuidString)
            ]
        )

        _ = try await tool.execute(
            args: [
                "query": .string("search my files"),
                ToolDiscoveryTool.sessionIDArgumentKey: .string(sessionID.uuidString)
            ]
        )

        let discovered = await ToolRegistry.shared.discoveredToolNames(for: sessionID)
        XCTAssertTrue(discovered.contains("messages.send"))
        XCTAssertTrue(discovered.contains("system.search_files"))
    }

    // MARK: - Helpers

    private func extractMatchedToolNames(from result: ToolResult) -> [String] {
        guard case .object(let root) = result.json,
              case .array(let matches)? = root["matches"] else {
            return []
        }

        return matches.compactMap { value in
            guard case .object(let match) = value else {
                return nil
            }
            return match["name"]?.stringValue
        }
    }
}
