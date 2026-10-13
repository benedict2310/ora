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
        XCTAssertTrue(checksum.output.hasPrefix("a1c6fd609f516b677c25f2b5bdc78063757f0d20056688b2362d41b241ad86a5 "), "Preserve the complete approved snapshot, not a single transitive pin.")
        let rootIgnored = try Self.run("/usr/bin/git", arguments: ["check-ignore", "--no-index", "Package.resolved"], in: Self.repoRoot)
        XCTAssertEqual(rootIgnored.status, 1, "The root lock must be eligible for tracking: \(rootIgnored.output)")
        let nestedIgnored = try Self.run("/usr/bin/git", arguments: ["check-ignore", "--no-index", "Vendor/example/Package.resolved"], in: Self.repoRoot)
        XCTAssertEqual(nestedIgnored.status, 0, "Only the root lock may be unignored.")
    }

    func test_packageResolutionUsesApprovedSparkleAndEventSourceAndPreservesOtherPins() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("Package.resolved"))
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(document["pins"] as? [[String: Any]])
        let summaries = try pins.map { pin -> String in
            let identity = try XCTUnwrap(pin["identity"] as? String)
            let state = try XCTUnwrap(pin["state"] as? [String: Any])
            let version = try XCTUnwrap(state["version"] as? String)
            let revision = try XCTUnwrap(state["revision"] as? String)
            return "\(identity)|\(version)|\(revision)"
        }.sorted()

        XCTAssertEqual(
            summaries.filter { $0.hasPrefix("sparkle|") },
            ["sparkle|2.10.0|eef1a539a373c1f1a320624b1130fc5de7b2e100"]
        )
        XCTAssertEqual(
            summaries.filter { $0.hasPrefix("eventsource|") },
            ["eventsource|1.5.1|86b5096ac59ab46e66bd1f6377c604bc1dab0bc2"]
        )
        XCTAssertEqual(
            summaries.filter { !$0.hasPrefix("sparkle|") && !$0.hasPrefix("eventsource|") },
            Self.approvedUnchangedPins.sorted(),
            "Only Sparkle and EventSource may change in the approved dependency graph."
        )
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

    private static let approvedUnchangedPins = [
        "async-http-client|1.35.0|4603a8036d921ea999fadb742931546c341f4bd7",
        "containerization|0.37.0|1d5641ff962456df021283505eaa6a701d828192",
        "fluidaudio|0.10.0|a1582f0c476864b6609f75459312037390089044",
        "grpc-swift-2|2.4.2|28cdd63ef88583ddc67d7bb179eab46fab465ce9",
        "grpc-swift-nio-transport|2.9.0|2ca31f06658ed288a2560e23ad649acbb3d6b3a3",
        "grpc-swift-protobuf|2.4.1|176c5a434fd76f6f479848d1a8f7d44967534168",
        "mlx-swift|0.31.4|dc43e62d7055353c7f99fa071a4e71d29dfddc44",
        "mlx-swift-lm|2.31.3|25b00d4e22e61ec9c41efda47990cd2084ec87ff",
        "mlxutilslibrary|0.0.7|66f7cd58026f335c46699f0f8030cb3bda495c54",
        "swift-algorithms|1.2.1|87e50f483c54e6efd60e885f7f5aa946cee68023",
        "swift-argument-parser|1.8.2|6a52f3251125d74daf04fcbd5e6f08a75d074382",
        "swift-asn1|1.7.1|a9a5efd40eaf558a2bcd48d64b1d1646be686008",
        "swift-async-algorithms|1.1.5|3da39bbc4e687d4192af7c9cf4eab805745a0b9c",
        "swift-atomics|1.3.1|0442cb5a3f98ab802acb777929fdb446bda11a34",
        "swift-certificates|1.19.3|89fbc3714264cce8db8e4ec51b64e01c3e28c6c5",
        "swift-collections|1.6.0|a0cb0954ecb21e4e31b0070e6ed5674e8556685a",
        "swift-configuration|1.2.0|be76c4ad929eb6c4bcaf3351799f2adf9e6848a9",
        "swift-crypto|3.15.1|95ba0316a9b733e92bb6b071255ff46263bbe7dc",
        "swift-distributed-tracing|1.4.1|dc4030184203ffafbb2ec614352487235d747fe0",
        "swift-http-structured-headers|1.7.0|933538faa42c432d385f02e07df0ace7c5ecfc47",
        "swift-http-types|1.6.0|db774a277f60063a32d854f2980299caf06da041",
        "swift-huggingface|0.9.0|b721959445b617d0bf03910b2b4aced345fd93bf",
        "swift-jinja|2.3.6|0b67ecb79139f6addef8699eff3622808aa6c7dc",
        "swift-log|1.14.0|a878e7f8f46cfc0e1125e565b5c08e7d5272dc9a",
        "swift-nio|2.101.2|cd3e1152083706d77b223fb29110e590efcc70c0",
        "swift-nio-extras|1.34.3|88a51340f59cf181ebde888bd1b749296b3ec029",
        "swift-nio-http2|1.44.0|61d1b44f6e4e118792be1cff88ee2bc0267c6f9a",
        "swift-nio-ssl|2.37.1|407d82d5b6cc00e1c3fb83a81b1539b70c788c5e",
        "swift-nio-transport-services|1.28.0|67787bb645a5e67d2edcdfbe48a216cc549222d5",
        "swift-numerics|1.1.1|0c0290ff6b24942dadb83a929ffaaa1481df04a2",
        "swift-protobuf|1.38.1|55d7a1cc5666b85c13464aea1c4b4a90feccb4c8",
        "swift-service-context|1.3.0|d0997351b0c7779017f88e7a93bc30a1878d7f29",
        "swift-service-lifecycle|2.11.0|9829955b385e5bb88128b73f1b8389e9b9c3191a",
        "swift-system|1.7.4|b5544ba79a70a0cb3563e75bf26dc198d6b40ed3",
        "swift-transformers|1.2.1|58c4bc11963a140358d791f678a60a2745a23146",
        "yyjson|0.12.0|8b4a38dc994a110abaec8a400615567bd996105f",
        "zipfoundation|0.9.20|22787ffb59de99e5dc1fbfe80b19c97a904ad48d",
        "zstd|1.5.7|f8745da6ff1ad1e7bab384bd1f9d742439278e99"
    ]

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
