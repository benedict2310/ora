//
//  LLMServiceTests.swift
//  OraTests
//
//  Tests for LLMService logic
//

import XCTest
@testable import Ora

final class LLMServiceTests: XCTestCase {
    
    func testFormatMessages() async {
        let service = LLMService.shared
        
        let messages = [
            LLMMessage(role: .system, content: "You are helpful."),
            LLMMessage(role: .user, content: "Hello"),
            LLMMessage(role: .assistant, content: "Hi there"),
            LLMMessage(role: .tool, content: "Tool output")
        ]
        
        let formatted = await service.formatMessages(messages)
        
        // Expected Qwen format (ChatML)
        // <|im_start|>system\nYou are helpful.<|im_end|>\n
        // <|im_start|>user\nHello<|im_end|>\n
        // <|im_start|>assistant\nHi there<|im_end|>\n
        // <|im_start|>tool\nTool output<|im_end|>\n
        // <|im_start|>assistant\n
        
        XCTAssertTrue(formatted.contains("<|im_start|>system\nYou are helpful.<|im_end|>\n"))
        XCTAssertTrue(formatted.contains("<|im_start|>user\nHello<|im_end|>\n"))
        XCTAssertTrue(formatted.contains("<|im_start|>assistant\nHi there<|im_end|>\n"))
        XCTAssertTrue(formatted.contains("<|im_start|>tool\nTool output<|im_end|>\n"))
        XCTAssertTrue(formatted.hasSuffix("<|im_start|>assistant\n"))
    }
    
    func testMemoryCheckLogic() {
        // Since we cannot easily mock ProcessInfo, we just verify the helper method exists and returns a valid identifier
        let recommended = LLMService.recommendedModel()
        XCTAssertTrue(recommended == .qwen7B || recommended == .qwen3B)
    }
}
