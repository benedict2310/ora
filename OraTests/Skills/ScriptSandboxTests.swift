//
//  ScriptSandboxTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class ScriptSandboxTests: XCTestCase {
    private var rootDirectory: URL!
    private var scriptsRoot: URL!
    private let sandbox = ScriptSandbox()

    override func setUpWithError() throws {
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptSandboxTests-\(UUID().uuidString)", isDirectory: true)
        self.scriptsRoot = self.rootDirectory.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: self.scriptsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func test_resolve_rejectsPathTraversal() throws {
        XCTAssertThrowsError(
            try self.sandbox.resolve(skillRoot: self.rootDirectory, scriptPath: "../secret.sh")
        ) { error in
            XCTAssertEqual(error as? ScriptSandboxError, .pathTraversal("../secret.sh"))
        }
    }

    func test_parseInterpreter_supportsCRLFShebang() throws {
        let scriptURL = self.scriptsRoot.appendingPathComponent("echo.sh", isDirectory: false)
        try "#!/bin/bash\r\necho hi\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        let interpreter = try self.sandbox.parseInterpreter(at: scriptURL)
        XCTAssertEqual(interpreter, "/bin/bash")
    }

    func test_parseInterpreter_rejectsEnvFlags() throws {
        let scriptURL = self.scriptsRoot.appendingPathComponent("bad.py", isDirectory: false)
        try "#!/usr/bin/env -S python3\nprint('hi')\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try self.sandbox.parseInterpreter(at: scriptURL)) { error in
            guard case .invalidShebang = error as? ScriptSandboxError else {
                return XCTFail("Expected invalid shebang error")
            }
        }
    }

    func test_parseInterpreter_usesExtensionFallbackWithoutShebang() throws {
        let scriptURL = self.scriptsRoot.appendingPathComponent("fallback.sh", isDirectory: false)
        try "echo hi\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        let interpreter = try self.sandbox.parseInterpreter(at: scriptURL)
        XCTAssertEqual(interpreter, "/bin/bash")
    }

    func test_resolve_rejectsScriptsRootSymlinkOutsideSkillRoot() throws {
        // Replace the scripts/ directory with a symlink pointing outside the skill root.
        try FileManager.default.removeItem(at: self.scriptsRoot)
        let externalTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalTarget) }

        // Write a script into the external target so the file exists.
        try "#!/bin/bash\necho hi\n".write(
            to: externalTarget.appendingPathComponent("escape.sh"),
            atomically: true,
            encoding: .utf8
        )

        // Symlink skillRoot/scripts → external directory
        try FileManager.default.createSymbolicLink(
            at: self.scriptsRoot,
            withDestinationURL: externalTarget
        )

        XCTAssertThrowsError(
            try self.sandbox.resolve(skillRoot: self.rootDirectory, scriptPath: "escape.sh")
        ) { error in
            XCTAssertEqual(error as? ScriptSandboxError, .pathTraversal("scripts"))
        }
    }
}
