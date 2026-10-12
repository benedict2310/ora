import XCTest

final class BuildScriptTests: XCTestCase {
    func test_generateProjectRegeneratesWhenSourceFilesAreNewer() throws {
        let buildScript = try Self.readBuildScript()
        let generateProjectBody = try XCTUnwrap(
            Self.functionBody(named: "generate_project", in: buildScript)
        )

        XCTAssertTrue(generateProjectBody.contains("-newer \"Ora.xcodeproj/project.pbxproj\""))
        XCTAssertTrue(generateProjectBody.contains("OraTests"))
        XCTAssertTrue(generateProjectBody.contains("OraCoreTests"))
    }

    func test_testModelsEnablesAndSelectsOnlyModelIntegrationSuites() throws {
        let buildScript = try Self.readBuildScript()
        let testModelsBody = try XCTUnwrap(Self.caseBody(named: "test-models", in: buildScript))

        XCTAssertTrue(testModelsBody.contains("ORA_RUN_MODEL_INTEGRATION_TESTS=1"))
        XCTAssertTrue(testModelsBody.contains("-only-testing:OraTests/LLMModelIntegrationTests"))
        XCTAssertTrue(testModelsBody.contains("-only-testing:OraTests/ParakeetModelIntegrationTests"))
        XCTAssertTrue(testModelsBody.contains("-only-testing:OraTests/EmbeddingModelIntegrationTests"))
    }

    func test_testPermsEnablesPermissionPromptsAndSelectsOnlyPermissionIntegrationSuites() throws {
        let buildScript = try Self.readBuildScript()
        let testPermsBody = try XCTUnwrap(Self.caseBody(named: "test-perms|test-permissions", in: buildScript))

        XCTAssertTrue(testPermsBody.contains("ORA_SKIP_PERMISSION_PROMPTS=0"))
        XCTAssertTrue(testPermsBody.contains("-only-testing:OraTests/PermissionsManagerIntegrationTests"))
        XCTAssertTrue(testPermsBody.contains("-only-testing:OraTests/LivePermissionsClientTests"))
        XCTAssertTrue(testPermsBody.contains("-only-testing:OraTests/PermissionHelperTests"))
        XCTAssertTrue(testPermsBody.contains("-only-testing:OraTests/AudioPermissionIntegrationTests"))
        XCTAssertFalse(
            testPermsBody.contains("ORA_SKIP_PERMISSION_PROMPTS=0 run_tests \"$SCHEME_LEGACY\"\n"),
            "test-perms must not run the entire legacy suite"
        )
    }

    func test_testTsanUsesXcodebuildThreadSanitizerFlag() throws {
        let buildScript = try Self.readBuildScript()
        let testTsanBody = try XCTUnwrap(Self.caseBody(named: "test-tsan", in: buildScript))

        XCTAssertTrue(
            testTsanBody.contains("-enableThreadSanitizer YES"),
            "./build.sh test-tsan must pass xcodebuild's -enableThreadSanitizer YES option so tests run with TSan instrumentation."
        )
        XCTAssertFalse(
            testTsanBody.contains("ENABLE_THREAD_SANITIZER=YES"),
            "ENABLE_THREAD_SANITIZER=YES is only a build setting and does not reliably enable the scheme diagnostic."
        )
    }

    func test_buildScriptRequiresAndCopiesTrackedResolution() throws {
        let script = try Self.readBuildScript()
        let generate = try XCTUnwrap(Self.functionBody(named: "generate_project", in: script))
        XCTAssertTrue(generate.contains("copy_package_resolution"))
        let copy = try XCTUnwrap(Self.functionBody(named: "copy_package_resolution", in: script))
        XCTAssertTrue(copy.contains("Package.resolved"))
        XCTAssertTrue(copy.contains("Ora.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"))
        XCTAssertTrue(copy.contains("return 1"), "Missing root lock must fail before invoking xcodebuild.")

        let checksum = try Self.run("/usr/bin/shasum", arguments: ["-a", "256", "Package.resolved"], in: Self.repoRoot)
        XCTAssertEqual(checksum.status, 0, checksum.output)
        XCTAssertTrue(checksum.output.hasPrefix("8516bec8d35c3f9bec2c6d79ac6559d4cfeeac9d18ad4e26df1afaf6b95897f6 "), "Preserve the complete approved snapshot, not a single transitive pin.")
        let rootIgnored = try Self.run("/usr/bin/git", arguments: ["check-ignore", "--no-index", "Package.resolved"], in: Self.repoRoot)
        XCTAssertEqual(rootIgnored.status, 1, "The root lock must be eligible for tracking: \(rootIgnored.output)")
        let nestedIgnored = try Self.run("/usr/bin/git", arguments: ["check-ignore", "--no-index", "Vendor/example/Package.resolved"], in: Self.repoRoot)
        XCTAssertEqual(nestedIgnored.status, 0, "Only the root lock may be unignored.")
    }

    func test_buildScriptCopiesResolutionWhenProjectAlreadyExists() throws {
        let fixture = try Self.makeBuildFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let rootLock = fixture.appendingPathComponent("Package.resolved")
        let generatedLock = fixture.appendingPathComponent("Ora.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        for contents in ["first approved snapshot\n", "replacement approved snapshot\n"] {
            try contents.write(to: rootLock, atomically: true, encoding: .utf8)
            let result = try Self.runFixture(fixture)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(try String(contentsOf: generatedLock, encoding: .utf8), contents)
        }
        let calls = try String(contentsOf: fixture.appendingPathComponent("xcodebuild.calls"), encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "-onlyUsePackageVersionsFromResolvedFile").count - 1, 2)
    }

    func test_buildScriptFailsBeforeXcodebuildWhenRootLockIsMissing() throws {
        let fixture = try Self.makeBuildFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = try Self.runFixture(fixture)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("required root Package.resolved is missing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("xcodebuild.calls").path))
    }

    func test_buildScriptPropagatesLockedResolverFailure() throws {
        let fixture = try Self.makeBuildFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "approved snapshot\n".write(to: fixture.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        let result = try Self.runFixture(fixture, exitStatus: "65")
        XCTAssertNotEqual(result.status, 0, "A rejected locked graph must not be reported as a successful build: \(result.output)")
        XCTAssertFalse(result.output.contains("Build succeeded"))
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func readBuildScript() throws -> String {
        try String(contentsOf: self.repoRoot.appendingPathComponent("build.sh"), encoding: .utf8)
    }

    private static func makeBuildFixture() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("OraBuildScriptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in ["bin", "Ora", "OraTests", "OraCoreTests"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: self.repoRoot.appendingPathComponent("build.sh"), to: fixture.appendingPathComponent("build.sh"))
        let stubs = [
            "xcodegen": """
                #!/bin/bash
                mkdir -p Ora.xcodeproj
                touch Ora.xcodeproj/project.pbxproj
                """,
            "xcodebuild": """
                #!/bin/bash
                printf '%s\\n' "$@" >> xcodebuild.calls
                if [ "${XCODEBUILD_EXIT_STATUS:-0}" != "0" ]; then
                  echo 'Package resolution refused'
                  exit "$XCODEBUILD_EXIT_STATUS"
                fi
                echo '** BUILD SUCCEEDED **'
                """
        ]
        for (name, contents) in stubs {
            let executable = fixture.appendingPathComponent("bin/\(name)")
            try contents.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        return fixture
    }

    private static func runFixture(_ fixture: URL, exitStatus: String = "0") throws -> (status: Int32, output: String) {
        try self.run("/bin/bash", arguments: [fixture.appendingPathComponent("build.sh").path, "build"], in: fixture, environment: [
            "PATH": fixture.appendingPathComponent("bin").path + ":/usr/bin:/bin",
            "XCODEBUILD_EXIT_STATUS": exitStatus
        ])
    }

    private static func run(_ executable: String, arguments: [String], in directory: URL, environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment {
            process.environment = environment
        }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let contents = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, contents)
    }

    private static func functionBody(named functionName: String, in script: String) -> String? {
        let marker = "\(functionName)() {"
        guard let startRange = script.range(of: marker) else { return nil }
        let afterMarker = script[startRange.upperBound...]
        guard let endRange = afterMarker.range(of: "\n}") else { return nil }
        return String(afterMarker[..<endRange.lowerBound])
    }

    private static func caseBody(named caseName: String, in script: String) -> String? {
        let marker = "  \(caseName))"
        guard let startRange = script.range(of: marker) else { return nil }
        let afterMarker = script[startRange.upperBound...]
        guard let endRange = afterMarker.range(of: "\n    ;;") else { return nil }
        return String(afterMarker[..<endRange.lowerBound])
    }
}
