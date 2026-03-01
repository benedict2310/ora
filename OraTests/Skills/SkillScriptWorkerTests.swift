//
//  SkillScriptWorkerTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillScriptWorkerTests: XCTestCase {
    private var rootDirectory: URL!
    private var skillRoot: URL!

    override func setUpWithError() throws {
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillScriptWorkerTests-\(UUID().uuidString)", isDirectory: true)
        self.skillRoot = self.rootDirectory.appendingPathComponent("skill", isDirectory: true)
        let scriptsRoot = self.skillRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func test_run_executesScriptAndCapturesOutput() async throws {
        let scriptURL = self.skillRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("echo.sh", isDirectory: false)
        try "#!/bin/bash\necho hello\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        let result = try await SkillScriptWorker.shared.run(
            skillID: "skill",
            skillRoot: self.skillRoot,
            scriptPath: "echo.sh",
            arguments: []
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("hello"))
    }

    func test_run_timesOutLongRunningScript() async {
        let scriptURL = self.skillRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("sleep.sh", isDirectory: false)
        try? "#!/bin/bash\nsleep 5\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        do {
            _ = try await SkillScriptWorker.shared.run(
                skillID: "skill",
                skillRoot: self.skillRoot,
                scriptPath: "sleep.sh",
                arguments: [],
                timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch let error as SkillScriptWorker.ScriptError {
            XCTAssertEqual(error, .timeout(0.1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
