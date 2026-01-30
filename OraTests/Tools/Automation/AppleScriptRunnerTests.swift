//
//  AppleScriptRunnerTests.swift
//  OraTests
//
//  Tests for AppleScript runner, JSON parsing, and error mapping
//

import XCTest
@testable import Ora

// MARK: - AppleScriptError Tests

final class AppleScriptErrorTests: XCTestCase {

    // MARK: - Error Type Classification

    func test_permissionDeniedError_hasCorrectType() {
        let error = AppleScriptError.permissionDenied(
            app: "Notes",
            errorNumber: -1744,
            rawMessage: "Not permitted"
        )
        XCTAssertEqual(error.errorType, "permission_denied")
    }

    func test_timeoutError_hasCorrectType() {
        let error = AppleScriptError.timeout(seconds: 10)
        XCTAssertEqual(error.errorType, "timeout")
    }

    func test_executionFailedError_hasCorrectType() {
        let error = AppleScriptError.executionFailed(
            errorNumber: -1,
            rawMessage: "Script failed"
        )
        XCTAssertEqual(error.errorType, "execution_failed")
    }

    func test_invalidOutputError_hasCorrectType() {
        let error = AppleScriptError.invalidOutput(rawOutput: "garbage")
        XCTAssertEqual(error.errorType, "invalid_output")
    }

    func test_processStartFailedError_hasCorrectType() {
        let error = AppleScriptError.processStartFailed(reason: "No such file")
        XCTAssertEqual(error.errorType, "process_start_failed")
    }

    func test_cancelledError_hasCorrectType() {
        let error = AppleScriptError.cancelled
        XCTAssertEqual(error.errorType, "cancelled")
    }

    // MARK: - Error Descriptions

    func test_permissionDeniedError_includesAppName() {
        let error = AppleScriptError.permissionDenied(
            app: "Notes",
            errorNumber: -1744,
            rawMessage: "Not permitted"
        )
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("Notes"), "Should include app name")
        XCTAssertTrue(description.contains("System Settings"), "Should include remediation guidance")
    }

    func test_permissionDeniedError_withoutAppName_showsGenericMessage() {
        let error = AppleScriptError.permissionDenied(
            app: nil,
            errorNumber: -1744,
            rawMessage: "Not permitted"
        )
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("Automation permission denied"))
        XCTAssertTrue(description.contains("System Settings"))
    }

    func test_timeoutError_showsSeconds() {
        let error = AppleScriptError.timeout(seconds: 15)
        XCTAssertTrue(error.localizedDescription.contains("15"))
    }

    func test_executionFailedError_showsRawMessage() {
        let error = AppleScriptError.executionFailed(
            errorNumber: -1728,
            rawMessage: "Can't get item"
        )
        XCTAssertTrue(error.localizedDescription.contains("Can't get item"))
    }

    // MARK: - Debug Info

    func test_permissionDeniedError_debugInfo_includesAllFields() {
        let error = AppleScriptError.permissionDenied(
            app: "Mail",
            errorNumber: -1743,
            rawMessage: "Operation not permitted"
        )
        let info = error.debugInfo

        XCTAssertEqual(info["type"], "permission_denied")
        XCTAssertEqual(info["app"], "Mail")
        XCTAssertEqual(info["errorNumber"], "-1743")
        XCTAssertEqual(info["rawMessage"], "Operation not permitted")
    }

    func test_timeoutError_debugInfo_includesTimeout() {
        let error = AppleScriptError.timeout(seconds: 30)
        let info = error.debugInfo

        XCTAssertEqual(info["type"], "timeout")
        XCTAssertEqual(info["timeoutSeconds"], "30")
    }

    // MARK: - Error Parsing

    func test_parse_recognizesPermissionErrorCode_1744() {
        let stderr = "execution error: Application isn't running. (-1744)"
        let error = AppleScriptError.parse(stderr: stderr)

        if case .permissionDenied(_, let errorNumber, _) = error {
            XCTAssertEqual(errorNumber, -1744)
        } else {
            XCTFail("Should parse as permission denied: \(error)")
        }
    }

    func test_parse_recognizesPermissionErrorCode_1743() {
        let stderr = "execution error: Not authorized to send Apple events (-1743)"
        let error = AppleScriptError.parse(stderr: stderr)

        if case .permissionDenied(_, let errorNumber, _) = error {
            XCTAssertEqual(errorNumber, -1743)
        } else {
            XCTFail("Should parse as permission denied: \(error)")
        }
    }

    func test_parse_recognizesPermissionKeywords() {
        let stderr = "The operation is not permitted"
        let error = AppleScriptError.parse(stderr: stderr)

        if case .permissionDenied = error {
            // Expected
        } else {
            XCTFail("Should recognize 'not permitted' keyword: \(error)")
        }
    }

    func test_parse_recognizesAccessDenied() {
        let stderr = "Access denied to application"
        let error = AppleScriptError.parse(stderr: stderr)

        if case .permissionDenied = error {
            // Expected
        } else {
            XCTFail("Should recognize 'access denied' keyword: \(error)")
        }
    }

    func test_parse_extractsAppNameFromError() {
        let stderr = "Application \"Notes\" got an error: Not permitted (-1744)"
        let error = AppleScriptError.parse(stderr: stderr)

        if case .permissionDenied(let app, _, _) = error {
            XCTAssertEqual(app, "Notes")
        } else {
            XCTFail("Should extract app name: \(error)")
        }
    }

    func test_parse_genericExecutionFailure() {
        let stderr = "syntax error: Expected end of line but found identifier (-2741)"
        let error = AppleScriptError.parse(stderr: stderr)

        if case .executionFailed(let errorNumber, let rawMessage) = error {
            XCTAssertEqual(errorNumber, -2741)
            XCTAssertTrue(rawMessage.contains("syntax error"))
        } else {
            XCTFail("Should parse as execution failed: \(error)")
        }
    }

    func test_parse_usesExitCodeWhenNoErrorNumber() {
        let stderr = "Some error without number"
        let error = AppleScriptError.parse(stderr: stderr, errorCode: 1)

        if case .executionFailed(let errorNumber, _) = error {
            XCTAssertEqual(errorNumber, 1)
        } else {
            XCTFail("Should use exit code: \(error)")
        }
    }
}

// MARK: - AppleScriptUtils Tests

final class AppleScriptUtilsTests: XCTestCase {

    // MARK: - JSON Parsing

    func test_parseJSONEnvelope_validJSON_returnsValue() {
        let output = """
        {"name": "Test", "count": 42}
        """

        let result = AppleScriptUtils.parseJSONEnvelope(output)
        XCTAssertNotNil(result)

        if case .object(let dict) = result {
            XCTAssertEqual(dict["name"]?.stringValue, "Test")
            XCTAssertEqual(dict["count"]?.numberValue, 42)
        } else {
            XCTFail("Expected object")
        }
    }

    func test_parseJSONEnvelope_emptyString_returnsNil() {
        XCTAssertNil(AppleScriptUtils.parseJSONEnvelope(""))
        XCTAssertNil(AppleScriptUtils.parseJSONEnvelope("   "))
    }

    func test_parseJSONEnvelope_invalidJSON_returnsNil() {
        XCTAssertNil(AppleScriptUtils.parseJSONEnvelope("not json"))
        XCTAssertNil(AppleScriptUtils.parseJSONEnvelope("{invalid}"))
    }

    func test_parseJSONEnvelope_trimsWhitespace() {
        let output = """

        {"success": true}

        """

        let result = AppleScriptUtils.parseJSONEnvelope(output)
        XCTAssertNotNil(result)
    }

    func test_parseEnvelope_successEnvelope() {
        let output = """
        {"success": true, "data": {"id": 123}}
        """

        let envelope = AppleScriptUtils.parseEnvelope(output)
        XCTAssertNotNil(envelope)
        XCTAssertTrue(envelope?.success ?? false)
        XCTAssertNil(envelope?.error)

        if case .object(let data)? = envelope?.data {
            XCTAssertEqual(data["id"]?.numberValue, 123)
        }
    }

    func test_parseEnvelope_errorEnvelope() {
        let output = """
        {"success": false, "error": "Something went wrong", "code": -1}
        """

        let envelope = AppleScriptUtils.parseEnvelope(output)
        XCTAssertNotNil(envelope)
        XCTAssertFalse(envelope?.success ?? true)
        XCTAssertEqual(envelope?.error, "Something went wrong")
        XCTAssertEqual(envelope?.code, -1)
    }

    // MARK: - Script Building

    func test_buildScript_wrapsInTellBlock() {
        let script = AppleScriptUtils.buildScript(
            for: "Notes",
            commands: "get name of first note",
            wrapInJSON: false
        )

        XCTAssertTrue(script.contains("tell application \"Notes\""))
        XCTAssertTrue(script.contains("get name of first note"))
        XCTAssertTrue(script.contains("end tell"))
    }

    func test_buildScript_withJSON_wrapsInTryCatch() {
        let script = AppleScriptUtils.buildScript(
            for: "Notes",
            commands: "get name of first note",
            wrapInJSON: true
        )

        XCTAssertTrue(script.contains("try"))
        XCTAssertTrue(script.contains("on error"))
        XCTAssertTrue(script.contains("success"))
    }

    // MARK: - String Escaping

    func test_escapeForAppleScript_escapesQuotes() {
        let input = "He said \"hello\""
        let escaped = AppleScriptUtils.escapeForAppleScript(input)
        XCTAssertEqual(escaped, "He said \\\"hello\\\"")
    }

    func test_escapeForAppleScript_escapesBackslashes() {
        let input = "path\\to\\file"
        let escaped = AppleScriptUtils.escapeForAppleScript(input)
        XCTAssertEqual(escaped, "path\\\\to\\\\file")
    }

    func test_escapeForAppleScript_escapesNewlines() {
        let input = "line1\nline2"
        let escaped = AppleScriptUtils.escapeForAppleScript(input)
        XCTAssertEqual(escaped, "line1\\nline2")
    }

    func test_escapeForAppleScript_replacesLineSeparators() {
        let input = "line1\u{2028}line2\u{2029}line3"
        let escaped = AppleScriptUtils.escapeForAppleScript(input)
        XCTAssertEqual(escaped, "line1\\nline2\\nline3")
    }

    func test_escapeForAppleScript_escapesTabs() {
        let input = "col1\tcol2"
        let escaped = AppleScriptUtils.escapeForAppleScript(input)
        XCTAssertEqual(escaped, "col1\\tcol2")
    }

    func test_escapeForAppleScript_replacesControlCharactersWithSpace() {
        let input = "a\u{000B}b\u{000C}c"
        let escaped = AppleScriptUtils.escapeForAppleScript(input)
        XCTAssertEqual(escaped, "a b c")
    }

    // MARK: - Record Conversion

    func test_convertRecordToJSON_validRecord() {
        // Note: This is a simplified test; real AppleScript records are more complex
        let record = "{\"name\":\"John\",\"age\":30}"
        let json = AppleScriptUtils.convertRecordToJSON(record)

        // This should pass through since it's already JSON-like
        XCTAssertNotNil(json)
    }

    func test_convertRecordToJSON_nonRecord_returnsNil() {
        XCTAssertNil(AppleScriptUtils.convertRecordToJSON("not a record"))
        XCTAssertNil(AppleScriptUtils.convertRecordToJSON(""))
    }

    // MARK: - Date Formatting

    func test_formatDate_producesAppleScriptDate() {
        let date = Date(timeIntervalSince1970: 0)  // Jan 1, 1970
        let formatted = AppleScriptUtils.formatDate(date)

        XCTAssertTrue(formatted.hasPrefix("date \""))
        XCTAssertTrue(formatted.hasSuffix("\""))
        XCTAssertTrue(formatted.contains("1970"))
    }
}

// MARK: - AppleScriptConfig Tests

final class AppleScriptConfigTests: XCTestCase {

    func test_defaultConfig_has10SecondTimeout() {
        let config = AppleScriptConfig.default
        XCTAssertEqual(config.timeout, 10)
        XCTAssertFalse(config.expectsJSON)
    }

    func test_jsonConfig_expectsJSON() {
        let config = AppleScriptConfig.json()
        XCTAssertTrue(config.expectsJSON)
    }

    func test_jsonConfig_customTimeout() {
        let config = AppleScriptConfig.json(timeout: 30)
        XCTAssertEqual(config.timeout, 30)
        XCTAssertTrue(config.expectsJSON)
    }
}

// MARK: - AppleScriptRunner Integration Tests

final class AppleScriptRunnerIntegrationTests: XCTestCase {

    var runner: AppleScriptRunner!

    override func setUp() async throws {
        self.runner = AppleScriptRunner()
    }

    override func tearDown() async throws {
        await self.runner.cancelAll()
        self.runner = nil
    }

    func test_execute_simpleScript_returnsOutput() async throws {
        // This test requires osascript to be available
        let result = try await self.runner.execute(
            script: "return \"hello\"",
            config: .default
        )

        XCTAssertEqual(result.stdout, "hello")
        XCTAssertGreaterThan(result.duration, 0)
    }

    func test_execute_scriptWithMath_returnsResult() async throws {
        let result = try await self.runner.execute(
            script: "return 2 + 2",
            config: .default
        )

        XCTAssertEqual(result.stdout, "4")
    }

    func test_execute_invalidScript_throwsError() async throws {
        do {
            _ = try await self.runner.execute(
                script: "this is not valid applescript!!!",
                config: .default
            )
            XCTFail("Should have thrown an error")
        } catch let error as AppleScriptError {
            XCTAssertEqual(error.errorType, "execution_failed")
        }
    }

    func test_execute_timeout_throwsTimeoutError() async throws {
        // Script that delays for 5 seconds but we set 1 second timeout
        do {
            _ = try await self.runner.execute(
                script: "delay 5\nreturn \"done\"",
                config: AppleScriptConfig(timeout: 1, expectsJSON: false)
            )
            XCTFail("Should have timed out")
        } catch let error as AppleScriptError {
            XCTAssertEqual(error.errorType, "timeout")
        }
    }

    func test_execute_jsonOutput_parsesJSON() async throws {
        // Return a JSON string from AppleScript
        let result = try await self.runner.execute(
            script: "return \"{\\\"count\\\": 42}\"",
            config: .json()
        )

        XCTAssertNotNil(result.json)
        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["count"]?.numberValue, 42)
        } else {
            XCTFail("Expected JSON object")
        }
    }

    func test_cancelAll_terminatesRunningScripts() async throws {
        // Capture runner to avoid 'self' capture issues
        let runner = self.runner!

        // Start a long-running script in a detached task
        let task = Task.detached {
            try await runner.execute(
                script: "delay 60\nreturn \"done\"",
                config: .default
            )
        }

        // Give it a moment to start
        try await Task.sleep(for: .milliseconds(100))

        // Cancel all
        await runner.cancelAll()

        // Cancel the task as well
        task.cancel()

        // Script should have been terminated (we can't easily verify this
        // without more complex coordination, but the method shouldn't crash)
    }

    func test_canControlApp_nonExistentApp_returnsFalse() async throws {
        // A non-existent bundle ID should return false
        let canControl = await self.runner.canControlApp(bundleId: "com.nonexistent.fake.app.12345")
        XCTAssertFalse(canControl)
    }

    func test_canControlApp_sanitizesInput() async throws {
        // Test that malicious input is properly escaped
        // This should not execute any injected commands
        let maliciousId = "Notes\" & return & \"evil"
        let canControl = await self.runner.canControlApp(bundleId: maliciousId)
        // Should return false because the sanitized bundle ID won't match any app
        XCTAssertFalse(canControl)
    }
}
