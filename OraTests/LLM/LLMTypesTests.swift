//
//  LLMTypesTests.swift
//  OraTests
//
//  Tests for LLM shared types and JSONValue helpers
//

import XCTest
@testable import Ora

final class LLMTypesTests: XCTestCase {

    func test_llmServiceError_descriptions() {
        XCTAssertEqual(LLMServiceError.notReady.errorDescription,
                       "LLM is not ready. Please wait for model loading.")
        XCTAssertEqual(LLMServiceError.modelNotFound.errorDescription,
                       "LLM model not found. Please download models first.")
        XCTAssertEqual(LLMServiceError.generationFailed("boom").errorDescription,
                       "Generation failed: boom")
        XCTAssertEqual(LLMServiceError.insufficientMemory.errorDescription,
                       "Insufficient memory to load the requested model.")
    }

    func test_llmMessage_codableRoundTrip() throws {
        let message = LLMMessage(role: .user, content: "Hello")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)

        XCTAssertEqual(decoded.role, message.role)
        XCTAssertEqual(decoded.content, message.content)
    }

    func test_jsonValue_accessors() {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.number(2).stringValue)

        XCTAssertEqual(JSONValue.number(2).numberValue, 2)
        XCTAssertNil(JSONValue.bool(true).numberValue)

        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertNil(JSONValue.string("no").boolValue)
    }

    func test_jsonValue_compactJSON_sortsKeys() {
        let value = JSONValue.object([
            "b": .number(2),
            "a": .number(1)
        ])
        let compact = value.compactJSON

        let rangeA = compact.range(of: "\"a\"")
        let rangeB = compact.range(of: "\"b\"")

        XCTAssertNotNil(rangeA)
        XCTAssertNotNil(rangeB)
        XCTAssertLessThan(rangeA!.lowerBound, rangeB!.lowerBound)
        XCTAssertFalse(compact.contains(" "))
    }

    func test_jsonValue_stringDescription_forArray() {
        let value = JSONValue.array([
            .string("a"),
            .number(2),
            .bool(true)
        ])

        let expected = "[\"a\",\(String(2.0)),true]"
        XCTAssertEqual(value.stringDescription, expected)
    }
}
