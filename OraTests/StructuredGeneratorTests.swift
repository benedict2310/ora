//
//  StructuredGeneratorTests.swift
//  OraTests
//
//  Tests for StructuredGenerator retry logic
//

import XCTest
@testable import Ora

final class StructuredGeneratorTests: XCTestCase {
    
    func testGenerate_SuccessFirstTry() async throws {
        let mockLLM = MockLLMService()
        await mockLLM.setResponses([
            """
            {
                "type": "response",
                "text": "Success"
            }
            """
        ])
        
        let generator = StructuredGenerator(llm: mockLLM)
        let result = try await generator.generate(messages: [])
        
        if case .response(let text) = result {
            XCTAssertEqual(text, "Success")
        } else {
            XCTFail("Expected response")
        }
        
        let count = await mockLLM.callCount
        XCTAssertEqual(count, 1)
    }
    
    func testGenerate_RetryOnMalformedJSON() async throws {
        let mockLLM = MockLLMService()
        await mockLLM.setResponses([
            "Not JSON",
            """
            {
                "type": "response",
                "text": "Fixed"
            }
            """
        ])
        
        let generator = StructuredGenerator(llm: mockLLM)
        let result = try await generator.generate(messages: [])
        
        if case .response(let text) = result {
            XCTAssertEqual(text, "Fixed")
        } else {
            XCTFail("Expected response")
        }
        
        let count = await mockLLM.callCount
        XCTAssertEqual(count, 2)
    }
    
    func testGenerate_RetryExhausted() async throws {
        let mockLLM = MockLLMService()
        await mockLLM.setResponses([
            "Bad 1",
            "Bad 2",
            "Bad 3"
        ])
        
        let generator = StructuredGenerator(llm: mockLLM)
        
        do {
            _ = try await generator.generate(messages: [])
            XCTFail("Expected error")
        } catch let error as StructuredGeneratorError {
            if case .validationFailed(let attempts, _) = error {
                XCTAssertEqual(attempts, 3)
            } else {
                XCTFail("Wrong error type")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        let count = await mockLLM.callCount
        XCTAssertEqual(count, 3)
    }
}

// MARK: - Mock

private actor MockLLMService: LLMServicing {
    var responses: [String] = []
    var callCount = 0
    
    func setResponses(_ responses: [String]) {
        self.responses = responses
    }
    
    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        callCount += 1
        let response = responses.isEmpty ? "" : responses.removeFirst()
        
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.finish()
        }
    }
    
    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
}
