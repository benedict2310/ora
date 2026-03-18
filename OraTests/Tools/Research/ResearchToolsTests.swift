//
//  ResearchToolsTests.swift
//  OraTests
//
//  Tests for research tools (research.start, research.list_results, research.load_result)
//

import XCTest
@testable import Ora

final class ResearchToolsTests: XCTestCase {

    // MARK: - ResearchStartTool Validation

    func test_researchStart_schema() {
        let tool = ResearchStartTool()
        XCTAssertEqual(tool.name, "research.start")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertEqual(tool.loadPolicy, .deferred)
        XCTAssertTrue(tool.schema.requiresConfirmation)
        // urls is no longer required — at least one of query or urls must be present
        XCTAssertTrue(tool.schema.requiredParameters.isEmpty)
    }

    func test_researchStart_validate_missingBothQueryAndURLs() {
        let tool = ResearchStartTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            if let researchError = error as? ResearchToolError,
               case .emptyInput = researchError {
                // Expected
            } else {
                XCTFail("Expected emptyInput error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_emptyArray() {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["urls": .array([])]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .emptyInput = researchError {
                // Expected — empty array with no query
            } else {
                XCTFail("Expected emptyInput error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_validURLs() throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = [
            "urls": .array([.string("https://example.com"), .string("https://other.com/page")])
        ]
        XCTAssertNoThrow(try tool.validate(args: args))
    }

    func test_researchStart_validate_singleStringURL() throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["urls": .string("https://example.com")]
        XCTAssertNoThrow(try tool.validate(args: args))
    }

    func test_researchStart_validate_tooManyURLs() {
        let tool = ResearchStartTool()
        let urls = (0...10).map { JSONValue.string("https://example.com/\($0)") }
        let args: [String: JSONValue] = ["urls": .array(urls)]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .tooManyURLs(let count, let limit) = researchError {
                XCTAssertEqual(count, 11)
                XCTAssertEqual(limit, 10)
            } else {
                XCTFail("Expected tooManyURLs error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_urlTooLong() {
        let tool = ResearchStartTool()
        let longURL = "https://example.com/" + String(repeating: "a", count: 2100)
        let args: [String: JSONValue] = ["urls": .array([.string(longURL)])]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .urlTooLong = researchError {
                // Expected
            } else {
                XCTFail("Expected urlTooLong error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_forbiddenScheme_data() {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["urls": .array([.string("data:text/html,<h1>test</h1>")])]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .forbiddenScheme(let scheme) = researchError {
                XCTAssertEqual(scheme, "data")
            } else {
                XCTFail("Expected forbiddenScheme error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_forbiddenScheme_javascript() {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["urls": .array([.string("javascript:alert(1)")])]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .forbiddenScheme(let scheme) = researchError {
                XCTAssertEqual(scheme, "javascript")
            } else {
                XCTFail("Expected forbiddenScheme error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_forbiddenScheme_file() {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["urls": .array([.string("file:///etc/passwd")])]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .forbiddenScheme(let scheme) = researchError {
                XCTAssertEqual(scheme, "file")
            } else {
                XCTFail("Expected forbiddenScheme error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_invalidURL() {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["urls": .array([.string("not a url at all")])]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .invalidURL = researchError {
                // Expected
            } else {
                XCTFail("Expected invalidURL error, got: \(error)")
            }
        }
    }

    func test_researchStart_validate_maxURLsBoundary() throws {
        let tool = ResearchStartTool()
        let urls = (0..<10).map { JSONValue.string("https://example.com/\($0)") }
        let args: [String: JSONValue] = ["urls": .array(urls)]
        XCTAssertNoThrow(try tool.validate(args: args))
    }

    // MARK: - Query Validation (BG.10)

    func test_researchStart_acceptsQueryParameter() throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["query": .string("latest Nvidia Blackwell server rollout")]
        XCTAssertNoThrow(try tool.validate(args: args))
    }

    func test_researchStart_acceptsQueryAndURLsTogether() throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = [
            "query": .string("Nvidia Blackwell"),
            "urls": .array([.string("https://nvidia.com/blackwell")])
        ]
        XCTAssertNoThrow(try tool.validate(args: args))
    }

    func test_researchStart_rejectsEmptyQueryAndNoURLs() {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = ["query": .string("   ")]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .emptyInput = researchError {
                // Expected
            } else {
                XCTFail("Expected emptyInput error, got: \(error)")
            }
        }
    }

    func test_researchStart_rejectsTooLongQuery() {
        let tool = ResearchStartTool()
        let longQuery = String(repeating: "a", count: 501)
        let args: [String: JSONValue] = ["query": .string(longQuery)]
        XCTAssertThrowsError(try tool.validate(args: args)) { error in
            if let researchError = error as? ResearchToolError,
               case .queryTooLong(let length, let limit) = researchError {
                XCTAssertEqual(length, 501)
                XCTAssertEqual(limit, 500)
            } else {
                XCTFail("Expected queryTooLong error, got: \(error)")
            }
        }
    }

    func test_researchStart_queryBoundary500Chars() throws {
        let tool = ResearchStartTool()
        let exactQuery = String(repeating: "a", count: 500)
        let args: [String: JSONValue] = ["query": .string(exactQuery)]
        XCTAssertNoThrow(try tool.validate(args: args))
    }

    // MARK: - Authorization Plan (BG.10)

    func test_researchStart_confirmationPromptShowsTopicForQuery() async throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = [
            "query": .string("Nvidia Blackwell server rollout")
        ]
        let plan = try await tool.authorizationPlan(args: args)
        if case .userConfirmation(let prompt) = plan.requirement {
            XCTAssertEqual(prompt.title, "Start Research Task")
            XCTAssertTrue(prompt.summary.contains("Nvidia Blackwell"))
            XCTAssertEqual(
                prompt.details,
                "This will search the public web and fetch sources in the background."
            )
        } else {
            XCTFail("Expected user confirmation requirement")
        }
    }

    func test_researchStart_confirmationPromptShowsURLsForURLs() async throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = [
            "urls": .array([.string("https://example.com")])
        ]
        let plan = try await tool.authorizationPlan(args: args)
        if case .userConfirmation(let prompt) = plan.requirement {
            XCTAssertEqual(prompt.title, "Start Research Task")
            XCTAssertTrue(prompt.details?.contains("https://example.com") ?? false)
        } else {
            XCTFail("Expected user confirmation requirement")
        }
    }

    func test_researchStart_confirmationPromptShowsBothForMixed() async throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = [
            "query": .string("Nvidia Blackwell"),
            "urls": .array([.string("https://nvidia.com")])
        ]
        let plan = try await tool.authorizationPlan(args: args)
        if case .userConfirmation(let prompt) = plan.requirement {
            XCTAssertTrue(prompt.summary.contains("Nvidia Blackwell"))
            XCTAssertTrue(prompt.details?.contains("nvidia.com") ?? false)
            XCTAssertTrue(prompt.details?.contains("fetch sources in the background") ?? false)
        } else {
            XCTFail("Expected user confirmation requirement")
        }
    }

    func test_researchStart_authorizationPlan_requiresConfirmation() async throws {
        let tool = ResearchStartTool()
        let args: [String: JSONValue] = [
            "urls": .array([.string("https://example.com")]),
            "label": .string("Test research")
        ]
        let plan = try await tool.authorizationPlan(args: args)
        if case .userConfirmation(let prompt) = plan.requirement {
            XCTAssertEqual(prompt.title, "Start Research Task")
            XCTAssertTrue(prompt.summary.contains("Test research"))
        } else {
            XCTFail("Expected user confirmation requirement")
        }
    }

    // MARK: - ResearchListResultsTool

    func test_researchListResults_schema() {
        let tool = ResearchListResultsTool()
        XCTAssertEqual(tool.name, "research.list_results")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertEqual(tool.loadPolicy, .deferred)
        XCTAssertFalse(tool.schema.requiresConfirmation)
    }

    func test_researchListResults_validate_noArgs() throws {
        let tool = ResearchListResultsTool()
        XCTAssertNoThrow(try tool.validate(args: [:]))
    }

    func test_researchListResults_validate_validLimit() throws {
        let tool = ResearchListResultsTool()
        XCTAssertNoThrow(try tool.validate(args: ["limit": .number(10)]))
    }

    func test_researchListResults_validate_invalidLimit() {
        let tool = ResearchListResultsTool()
        XCTAssertThrowsError(try tool.validate(args: ["limit": .string("ten")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("number"), "Error should mention 'number': \(error)")
        }
    }

    // MARK: - ResearchLoadResultTool

    func test_researchLoadResult_schema() {
        let tool = ResearchLoadResultTool()
        XCTAssertEqual(tool.name, "research.load_result")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertEqual(tool.loadPolicy, .deferred)
        XCTAssertFalse(tool.schema.requiresConfirmation)
        XCTAssertTrue(tool.schema.requiredParameters.contains("task_id"))
    }

    func test_researchLoadResult_validate_missingTaskID() {
        let tool = ResearchLoadResultTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("task_id"), "Error should mention 'task_id': \(error)")
        }
    }

    func test_researchLoadResult_validate_emptyTaskID() {
        let tool = ResearchLoadResultTool()
        XCTAssertThrowsError(try tool.validate(args: ["task_id": .string("")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("task_id"))
        }
    }

    func test_researchLoadResult_validate_invalidUUID() {
        let tool = ResearchLoadResultTool()
        XCTAssertThrowsError(try tool.validate(args: ["task_id": .string("not-a-uuid")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("UUID"))
        }
    }

    func test_researchLoadResult_validate_validUUID() throws {
        let tool = ResearchLoadResultTool()
        let taskID = UUID().uuidString
        XCTAssertNoThrow(try tool.validate(args: ["task_id": .string(taskID)]))
    }

    // MARK: - ResearchLoadResultTool Helpers

    func test_capString_withinLimit() {
        let result = ResearchLoadResultTool.capString("Hello world", maxLength: 100)
        XCTAssertEqual(result, "Hello world")
    }

    func test_capString_exceedsLimit() {
        let result = ResearchLoadResultTool.capString("Hello world, this is a test", maxLength: 10)
        XCTAssertEqual(result, "Hello w...")
        XCTAssertEqual(result.count, 10)
    }

    func test_capString_exactLimit() {
        let result = ResearchLoadResultTool.capString("12345", maxLength: 5)
        XCTAssertEqual(result, "12345")
    }

    // MARK: - ResearchStartTool URL Extraction

    func test_extractURLs_fromArray() throws {
        let args: [String: JSONValue] = [
            "urls": .array([.string("https://a.com"), .string("https://b.com")])
        ]
        let urls = try ResearchStartTool.extractURLs(from: args)
        XCTAssertEqual(urls, ["https://a.com", "https://b.com"])
    }

    func test_extractURLs_fromSingleString() throws {
        let args: [String: JSONValue] = ["urls": .string("https://a.com")]
        let urls = try ResearchStartTool.extractURLs(from: args)
        XCTAssertEqual(urls, ["https://a.com"])
    }

    func test_extractURLs_invalidType() {
        let args: [String: JSONValue] = ["urls": .number(42)]
        XCTAssertThrowsError(try ResearchStartTool.extractURLs(from: args))
    }

    // MARK: - Query Extraction

    func test_extractQuery_valid() {
        let args: [String: JSONValue] = ["query": .string("test query")]
        let query = ResearchStartTool.extractQuery(from: args)
        XCTAssertEqual(query, "test query")
    }

    func test_extractQuery_nil() {
        let query = ResearchStartTool.extractQuery(from: [:])
        XCTAssertNil(query)
    }

    func test_extractQuery_trims() {
        let args: [String: JSONValue] = ["query": .string("  test  ")]
        let query = ResearchStartTool.extractQuery(from: args)
        XCTAssertEqual(query, "test")
    }

    func test_extractQuery_emptyIsNil() {
        let args: [String: JSONValue] = ["query": .string("   ")]
        let query = ResearchStartTool.extractQuery(from: args)
        XCTAssertNil(query)
    }

    // MARK: - ResearchToolError Descriptions

    func test_researchToolError_tooManyURLs_description() {
        let error = ResearchToolError.tooManyURLs(count: 15, limit: 10)
        XCTAssertTrue(error.errorDescription!.contains("15"))
        XCTAssertTrue(error.errorDescription!.contains("10"))
    }

    func test_researchToolError_forbiddenScheme_description() {
        let error = ResearchToolError.forbiddenScheme(scheme: "file")
        XCTAssertTrue(error.errorDescription!.contains("file"))
    }

    func test_researchToolError_cooldownActive_description() {
        let error = ResearchToolError.cooldownActive(remainingSeconds: 15)
        XCTAssertTrue(error.errorDescription!.contains("15"))
    }

    func test_researchToolError_sessionLimitExceeded_description() {
        let error = ResearchToolError.sessionLimitExceeded(limit: 5)
        XCTAssertTrue(error.errorDescription!.contains("5"))
    }

    func test_researchToolError_queryTooLong_description() {
        let error = ResearchToolError.queryTooLong(length: 600, limit: 500)
        XCTAssertTrue(error.errorDescription!.contains("600"))
        XCTAssertTrue(error.errorDescription!.contains("500"))
    }

    func test_researchToolError_emptyInput_description() {
        let error = ResearchToolError.emptyInput
        XCTAssertTrue(error.errorDescription!.contains("query"))
        XCTAssertTrue(error.errorDescription!.contains("URL"))
    }

    // MARK: - Registration

    func test_researchTools_registeredInDefaultTools() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let startTool = await ToolRegistry.shared.tool(named: "research.start")
        let listTool = await ToolRegistry.shared.tool(named: "research.list_results")
        let loadTool = await ToolRegistry.shared.tool(named: "research.load_result")

        XCTAssertNotNil(startTool, "research.start should be registered")
        XCTAssertNotNil(listTool, "research.list_results should be registered")
        XCTAssertNotNil(loadTool, "research.load_result should be registered")

        // Cleanup
        await ToolRegistry.shared.clear()
    }

    func test_researchTools_areDeferred() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let deferred = await ToolRegistry.shared.deferredCatalogRows()
        let deferredNames = Set(deferred.map(\.name))

        XCTAssertTrue(deferredNames.contains("research.start"))
        XCTAssertTrue(deferredNames.contains("research.list_results"))
        XCTAssertTrue(deferredNames.contains("research.load_result"))

        // Cleanup
        await ToolRegistry.shared.clear()
    }

    // MARK: - Tool output hygiene (BG.10)

    func test_researchToolsRemainDeferred() {
        let startTool = ResearchStartTool()
        let listTool = ResearchListResultsTool()
        let loadTool = ResearchLoadResultTool()

        XCTAssertEqual(startTool.loadPolicy, .deferred)
        XCTAssertEqual(listTool.loadPolicy, .deferred)
        XCTAssertEqual(loadTool.loadPolicy, .deferred)
    }
}
