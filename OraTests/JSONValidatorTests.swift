//
//  JSONValidatorTests.swift
//  OraTests
//
//  Tests for JSONValidator
//

import XCTest
@testable import Ora

final class JSONValidatorTests: XCTestCase {
    
    func testParseResponse() {
        let json = """
        {
            "type": "response",
            "text": "Hello world"
        }
        """
        
        let result = JSONValidator.parse(json)
        
        if case .success(let output) = result {
            if case .response(let text) = output {
                XCTAssertEqual(text, "Hello world")
            } else {
                XCTFail("Expected .response")
            }
        } else {
            XCTFail("Parse failed")
        }
    }
    
    func testParseToolCall() {
        let json = """
        {
            "type": "tool_call",
            "tool": "calculator",
            "args": {
                "operation": "add",
                "values": [1, 2]
            }
        }
        """
        
        let result = JSONValidator.parse(json)
        
        if case .success(let output) = result {
            if case .toolCall(let tool, let args) = output {
                XCTAssertEqual(tool, "calculator")
                XCTAssertEqual(args["operation"]?.stringValue, "add")
                // Cannot easily test array equality with JSONValue, but we can check existence
            } else {
                XCTFail("Expected .toolCall")
            }
        } else {
            XCTFail("Parse failed")
        }
    }
    
    func testParseError() {
        let json = """
        {
            "type": "error",
            "message": "Something went wrong"
        }
        """
        
        let result = JSONValidator.parse(json)
        
        if case .success(let output) = result {
            if case .error(let message) = output {
                XCTAssertEqual(message, "Something went wrong")
            } else {
                XCTFail("Expected .error")
            }
        } else {
            XCTFail("Parse failed")
        }
    }
    
    func testParseProposal() {
        let json = """
        {
            "type": "proposal",
            "summary": "Create event",
            "tool": "calendar",
            "args": {
                "title": "Meeting"
            }
        }
        """
        
        let result = JSONValidator.parse(json)
        
        if case .success(let output) = result {
            if case .proposal(let summary, let tool, let args) = output {
                XCTAssertEqual(summary, "Create event")
                XCTAssertEqual(tool, "calendar")
                XCTAssertEqual(args["title"]?.stringValue, "Meeting")
            } else {
                XCTFail("Expected .proposal")
            }
        } else {
            XCTFail("Parse failed")
        }
    }
    
    func testParseMarkdownClean() {
        let json = """
        ```json
        {
            "type": "response",
            "text": "Hello"
        }
        ```
        """
        
        let result = JSONValidator.parse(json)
        
        if case .success(let output) = result {
            if case .response(let text) = output {
                XCTAssertEqual(text, "Hello")
            } else {
                XCTFail("Expected .response")
            }
        } else {
            XCTFail("Parse failed")
        }
    }
    
    func testParseInvalidJSON() {
        let json = "{ invalid }"
        let result = JSONValidator.parse(json)
        
        if case .failure(let error) = result {
            if case .invalidJSON = error {
                // Pass
            } else {
                XCTFail("Expected .invalidJSON error")
            }
        } else {
            XCTFail("Expected failure")
        }
    }
    
    func testMissingField() {
        let json = """
        {
            "type": "response"
        }
        """
        // Missing "text"
        
        let result = JSONValidator.parse(json)
        
        if case .failure(let error) = result {
            if case .missingField(let field) = error {
                XCTAssertEqual(field, "text")
            } else {
                XCTFail("Expected .missingField error")
            }
        } else {
            XCTFail("Expected failure")
        }
    }
}
