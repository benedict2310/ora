//
//  ToolHostTests.swift
//  OraTests
//
//  Tests for ToolHost
//

import XCTest
@testable import Ora

final class ToolHostTests: XCTestCase {
    
    override func setUp() async throws {
        await ToolRegistry.shared.clear()
        // Note: AuditLogger is tricky to clear/mock without DI, but we verify side effects mainly
    }
    
    func test_executeReadTool_success() async throws {
        let tool = MockReadTool()
        await ToolRegistry.shared.register(tool)
        
        let result = try await ToolHost.shared.execute(
            toolName: "mock.read",
            args: [:],
            confirmed: false
        )
        
        XCTAssertEqual(result.humanSummary, "Read success")
    }
    
    func test_executeMutateTool_needsConfirmation() async {
        let tool = MockMutateTool()
        await ToolRegistry.shared.register(tool)
        
        do {
            _ = try await ToolHost.shared.execute(
                toolName: "mock.mutate",
                args: [:],
                confirmed: false
            )
            XCTFail("Should have thrown confirmationRequired")
        } catch let error as ToolHostError {
            XCTAssertEqual(error, .confirmationRequired("mock.mutate"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func test_executeMutateTool_confirmed_success() async throws {
        let tool = MockMutateTool()
        await ToolRegistry.shared.register(tool)
        
        let result = try await ToolHost.shared.execute(
            toolName: "mock.mutate",
            args: [:],
            confirmed: true
        )
        
        XCTAssertEqual(result.humanSummary, "Mutate success")
    }
    
    func test_toolNotFound() async {
        do {
            _ = try await ToolHost.shared.execute(
                toolName: "nonexistent",
                args: [:],
                confirmed: false
            )
            XCTFail("Should have thrown toolNotFound")
        } catch let error as ToolHostError {
            XCTAssertEqual(error, .toolNotFound("nonexistent"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func test_validationFailed() async {
        let tool = MockValidatingTool()
        await ToolRegistry.shared.register(tool)
        
        do {
            _ = try await ToolHost.shared.execute(
                toolName: "mock.validate",
                args: ["valid": .bool(false)],
                confirmed: false
            )
            XCTFail("Should have thrown validationFailed")
        } catch let error as ToolHostError {
            if case .validationFailed(let name, _) = error {
                XCTAssertEqual(name, "mock.validate")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func test_auditLog_recorded() async throws {
        // Clear previous logs
        await AuditLogger.shared.clearAll()
        
        let tool = MockReadTool()
        await ToolRegistry.shared.register(tool)
        
        _ = try await ToolHost.shared.execute(
            toolName: "mock.read",
            args: ["arg": .string("value")],
            confirmed: false
        )
        
        let entries = await AuditLogger.shared.fetchEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.toolName, "mock.read")
        XCTAssertEqual(entry.action, "read")
        XCTAssertTrue(entry.success)
        
        // Verify parameters were stored
        let params = try XCTUnwrap(entry.parameters)
        XCTAssertEqual(params["arg"] as? String, "value")
    }
}

// MARK: - Mock Validating Tool

struct MockValidatingTool: Tool {
    let name = "mock.validate"
    let kind: ToolKind = .read
    let schema = ToolSchema(
        name: "mock.validate",
        description: "A validating tool",
        parameters: [:],
        requiredParameters: []
    )
    
    enum ValidationError: Error {
        case invalidArg
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let valid = args["valid"]?.boolValue, valid else {
            throw ValidationError.invalidArg
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        return .success(.null, summary: "Valid")
    }
}
