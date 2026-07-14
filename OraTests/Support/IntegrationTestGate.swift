//
//  IntegrationTestGate.swift
//  OraTests
//
//  Explicit opt-in gate for tests that load real local models.
//

import XCTest

enum IntegrationTestGate {
    static let modelIntegrationEnvironmentKey = "ORA_RUN_MODEL_INTEGRATION_TESTS"
    static let permissionIntegrationEnvironmentKey = "ORA_SKIP_PERMISSION_PROMPTS"

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[modelIntegrationEnvironmentKey] == "1"
    }

    static func requireModelTestsEnabled() throws {
        try requireModelTestsEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func requireModelTestsEnabled(environment: [String: String]) throws {
        guard isEnabled(environment: environment) else {
            throw XCTSkip(
                "Model integration tests are disabled. Set ORA_RUN_MODEL_INTEGRATION_TESTS=1 to run them."
            )
        }
    }

    static func isPermissionEnabled(environment: [String: String]) -> Bool {
        environment[permissionIntegrationEnvironmentKey] == "0"
    }

    static func requirePermissionTestsEnabled() throws {
        try requirePermissionTestsEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func requirePermissionTestsEnabled(environment: [String: String]) throws {
        guard isPermissionEnabled(environment: environment) else {
            throw XCTSkip(
                "Permission integration tests are disabled. Set ORA_SKIP_PERMISSION_PROMPTS=0 to run them."
            )
        }
    }
}
