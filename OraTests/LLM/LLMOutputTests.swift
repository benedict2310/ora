//
//  LLMOutputTests.swift
//  OraTests
//
//  Tests for LLMOutput enum
//

import XCTest
@testable import Ora

final class LLMOutputTests: XCTestCase {

    func test_llmOutput_response_equality() {
        XCTAssertEqual(LLMOutput.response(text: "Hi"), LLMOutput.response(text: "Hi"))
        XCTAssertNotEqual(LLMOutput.response(text: "Hi"), LLMOutput.response(text: "Bye"))
    }

    func test_llmOutput_toolCall_equality() {
        let args: [String: JSONValue] = ["id": .string("123"), "count": .number(2)]
        let output = LLMOutput.toolCall(tool: "calendar.query", args: args)
        XCTAssertEqual(output, LLMOutput.toolCall(tool: "calendar.query", args: args))
        XCTAssertNotEqual(output, LLMOutput.toolCall(tool: "calendar.find", args: args))
    }

    func test_llmOutput_proposal_equality() {
        let args: [String: JSONValue] = ["title": .string("Standup")]
        let output = LLMOutput.proposal(summary: "Create", tool: "calendar.create_event", args: args)
        XCTAssertEqual(output, LLMOutput.proposal(summary: "Create", tool: "calendar.create_event", args: args))
        XCTAssertNotEqual(output, LLMOutput.proposal(summary: "Other", tool: "calendar.create_event", args: args))
    }

    func test_llmOutput_error_equality() {
        XCTAssertEqual(LLMOutput.error(message: "Oops"), LLMOutput.error(message: "Oops"))
        XCTAssertNotEqual(LLMOutput.error(message: "Oops"), LLMOutput.error(message: "Different"))
    }
}
