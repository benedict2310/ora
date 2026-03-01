//
//  ToolAuthorizationTests.swift
//  OraTests
//
//  Focused tests for ToolHost preflight and ticket/receipt validation.
//

import XCTest
@testable import Ora

final class ToolAuthorizationTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.clear()
    }

    override func tearDown() async throws {
        await ToolRegistry.shared.clear()
    }

    func test_preflight_readTool_returnsImmediateReceipt() async throws {
        await ToolRegistry.shared.register(MockReadTool())

        let result = try await ToolHost.shared.preflight(toolName: "mock.read", args: [:])

        guard case .allowed(let receipt) = result.disposition else {
            return XCTFail("Expected immediate authorization")
        }

        XCTAssertEqual(receipt.ticketID, result.ticket.id)
        XCTAssertEqual(receipt.toolName, "mock.read")
    }

    func test_preflight_mutateTool_requiresUserAuthorization() async throws {
        await ToolRegistry.shared.register(MockMutateTool())

        let result = try await ToolHost.shared.preflight(toolName: "mock.mutate", args: [:])

        guard case .requiresUser = result.disposition else {
            return XCTFail("Expected interactive authorization")
        }
    }

    func test_executeAuthorized_rejectsReceiptReplay() async throws {
        await ToolRegistry.shared.register(MockMutateTool())

        let preflight = try await ToolHost.shared.preflight(toolName: "mock.mutate", args: [:])
        guard case .requiresUser = preflight.disposition else {
            return XCTFail("Expected interactive authorization")
        }

        let receipt = try await ToolHost.shared.authorize(
            ticketID: preflight.ticket.id,
            decision: .approveOnce
        )

        _ = try await ToolHost.shared.executeAuthorized(ticket: preflight.ticket, receipt: receipt)

        do {
            _ = try await ToolHost.shared.executeAuthorized(ticket: preflight.ticket, receipt: receipt)
            XCTFail("Expected invalid receipt error")
        } catch let error as ToolHostError {
            XCTAssertEqual(error, .invalidAuthorizationTicket)
        }
    }
}
