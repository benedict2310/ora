//
//  IntegrationTestGateTests.swift
//  OraTests
//
//  Tests for explicit model integration opt-in behavior.
//

import XCTest
@testable import Ora

final class IntegrationTestGateTests: XCTestCase {
    func test_isEnabled_defaultsToFalseWhenEnvironmentVariableIsUnset() {
        XCTAssertFalse(IntegrationTestGate.isEnabled(environment: [:]))
    }

    func test_isEnabled_rejectsZeroAndFalseValues() {
        XCTAssertFalse(IntegrationTestGate.isEnabled(environment: ["ORA_RUN_MODEL_INTEGRATION_TESTS": "0"]))
        XCTAssertFalse(IntegrationTestGate.isEnabled(environment: ["ORA_RUN_MODEL_INTEGRATION_TESTS": "false"]))
    }

    func test_isEnabled_acceptsOnlyOneValue() {
        XCTAssertTrue(IntegrationTestGate.isEnabled(environment: ["ORA_RUN_MODEL_INTEGRATION_TESTS": "1"]))
        XCTAssertFalse(IntegrationTestGate.isEnabled(environment: ["ORA_RUN_MODEL_INTEGRATION_TESTS": "TRUE"]))
        XCTAssertFalse(IntegrationTestGate.isEnabled(environment: ["ORA_RUN_MODEL_INTEGRATION_TESTS": " 1 "]))
    }

    func test_requireModelTestsEnabled_throwsSkipWhenDisabled() {
        XCTAssertThrowsError(try IntegrationTestGate.requireModelTestsEnabled(environment: [:])) { error in
            XCTAssertTrue(error is XCTSkip)
        }
    }

    func test_requireModelTestsEnabled_doesNotThrowWhenEnabled() {
        XCTAssertNoThrow(
            try IntegrationTestGate.requireModelTestsEnabled(
                environment: ["ORA_RUN_MODEL_INTEGRATION_TESTS": "1"]
            )
        )
    }

    func test_permissionTests_areDisabledByDefault() {
        XCTAssertFalse(IntegrationTestGate.isPermissionEnabled(environment: [:]))
        XCTAssertFalse(IntegrationTestGate.isPermissionEnabled(environment: ["ORA_SKIP_PERMISSION_PROMPTS": "1"]))
    }

    func test_permissionTests_areEnabledOnlyWhenPermissionPromptsAreAllowed() {
        XCTAssertTrue(IntegrationTestGate.isPermissionEnabled(environment: ["ORA_SKIP_PERMISSION_PROMPTS": "0"]))
        XCTAssertFalse(IntegrationTestGate.isPermissionEnabled(environment: ["ORA_SKIP_PERMISSION_PROMPTS": "true"]))
        XCTAssertFalse(IntegrationTestGate.isPermissionEnabled(environment: ["ORA_SKIP_PERMISSION_PROMPTS": " 0 "]))
    }

    func test_requirePermissionTestsEnabled_skipsWhenPromptsAreDisabled() {
        XCTAssertThrowsError(try IntegrationTestGate.requirePermissionTestsEnabled(environment: [:])) { error in
            XCTAssertTrue(error is XCTSkip)
        }
    }

    func test_requirePermissionTestsEnabled_doesNotThrowWhenPromptsAreAllowed() {
        XCTAssertNoThrow(
            try IntegrationTestGate.requirePermissionTestsEnabled(
                environment: ["ORA_SKIP_PERMISSION_PROMPTS": "0"]
            )
        )
    }
}
