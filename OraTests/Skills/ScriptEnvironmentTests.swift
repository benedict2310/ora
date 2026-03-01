//
//  ScriptEnvironmentTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class ScriptEnvironmentTests: XCTestCase {
    func test_build_includesOnlyAllowedKeysAndOraContext() {
        let env = ScriptEnvironment.build(
            requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            skillID: "weather-helper",
            skillRoot: URL(fileURLWithPath: "/tmp/weather-helper", isDirectory: true),
            scriptName: "fetch.py"
        )

        XCTAssertEqual(env.values["ORA_SKILL_ID"], "weather-helper")
        XCTAssertEqual(env.values["ORA_SCRIPT_NAME"], "fetch.py")
        XCTAssertEqual(env.values["ORA_SKILL_ROOT"], "/tmp/weather-helper")
        XCTAssertEqual(env.values["ORA_REQUEST_ID"], "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertNotNil(env.values["PATH"])
        XCTAssertNil(env.values["SSH_AUTH_SOCK"])
    }
}
