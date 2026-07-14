//
//  IntegrationTestGate.swift
//  OraTests
//
//  Explicit opt-in gate for tests that load real local models.
//

import XCTest

enum IntegrationTestGate {
    static let modelIntegrationEnvironmentKey = "ORA_RUN_MODEL_INTEGRATION_TESTS"

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
}
