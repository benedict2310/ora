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

    func testUnknownType() {
        let json = """
        {
            "type": "unknown"
        }
        """

        let result = JSONValidator.parse(json)

        if case .failure(let error) = result {
            if case .unknownType(let type) = error {
                XCTAssertEqual(type, "unknown")
            } else {
                XCTFail("Expected .unknownType error")
            }
        } else {
            XCTFail("Expected failure")
        }
    }

    func testNotAnObject() {
        let json = "[1, 2, 3]"
        let result = JSONValidator.parse(json)

        if case .failure(let error) = result {
            if case .notAnObject = error {
                // Pass
            } else {
                XCTFail("Expected .notAnObject error")
            }
        } else {
            XCTFail("Expected failure")
        }
    }

    func testParseToolCall_mapsBoolAndNumber() {
        let json = """
        {
            "type": "tool_call",
            "tool": "calendar.query",
            "args": {
                "all_day": true,
                "limit": 5
            }
        }
        """

        let result = JSONValidator.parse(json)

        if case .success(let output) = result {
            if case .toolCall(_, let args) = output {
                XCTAssertEqual(args["all_day"]?.boolValue, true)
                XCTAssertEqual(args["limit"]?.numberValue, 5)
            } else {
                XCTFail("Expected .toolCall")
            }
        } else {
            XCTFail("Parse failed")
        }
    }

    func testValidationError_descriptions() {
        XCTAssertEqual(JSONValidationError.invalidEncoding.errorDescription, "Invalid text encoding")
        XCTAssertEqual(JSONValidationError.notAnObject.errorDescription, "Expected JSON object at root")
        XCTAssertEqual(JSONValidationError.missingField("tool").errorDescription, "Missing required field: tool")
        XCTAssertEqual(JSONValidationError.unknownType("foo").errorDescription, "Unknown response type: foo")
    }
}
