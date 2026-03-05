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
        XCTAssertEqual(
            LLMServiceError.unsupportedInput("Unsupported").errorDescription,
            "Unsupported"
        )
    }

    func test_llmMessage_codableRoundTrip() throws {
        let message = LLMMessage(role: .user, content: "Hello")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)

        XCTAssertEqual(decoded.role, message.role)
        XCTAssertEqual(decoded.content, message.content)
        XCTAssertEqual(decoded.contentParts, [.text("Hello")])
    }

    func test_llmMessage_multimodalRoundTrip_preservesContentParts() throws {
        let image = LLMImageAttachmentReference(
            attachmentID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            stagedFilePath: "/tmp/ora/staged/screenshot-1.png",
            mimeType: "image/png",
            byteCount: 1024,
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        let message = LLMMessage(
            role: .user,
            contentParts: [
                .text("Please inspect this screenshot."),
                .image(image),
            ]
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)

        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.contentParts, message.contentParts)
        XCTAssertEqual(decoded.content, "Please inspect this screenshot.")
        XCTAssertTrue(decoded.containsImageAttachments)
        XCTAssertEqual(decoded.imageAttachments, [image])
    }

    func test_llmMessage_decodeLegacyStringContent_mapsToTextPart() throws {
        let legacyJSON = #"{"role":"assistant","content":"Legacy text"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: legacyJSON)

        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.content, "Legacy text")
        XCTAssertEqual(decoded.contentParts, [.text("Legacy text")])
    }

    func test_llmMessage_textOnlyEncode_keepsLegacyContentKey() throws {
        let message = LLMMessage(role: .tool, content: "Tool output")
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["role"] as? String, "tool")
        XCTAssertEqual(json?["content"] as? String, "Tool output")
        XCTAssertNil(json?["contentParts"])
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
