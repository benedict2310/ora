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

    private static func readBuildScript() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // BuildScriptTests.swift -> Scripts
            .deletingLastPathComponent() // Scripts -> OraCoreTests
            .deletingLastPathComponent() // OraCoreTests -> repository root
        let buildScriptURL = repoRoot.appendingPathComponent("build.sh")
        return try String(contentsOf: buildScriptURL, encoding: .utf8)
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
