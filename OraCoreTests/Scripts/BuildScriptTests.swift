import XCTest

final class BuildScriptTests: XCTestCase {
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

    private static func caseBody(named caseName: String, in script: String) -> String? {
        let marker = "  \(caseName))"
        guard let startRange = script.range(of: marker) else { return nil }
        let afterMarker = script[startRange.upperBound...]
        guard let endRange = afterMarker.range(of: "\n    ;;") else { return nil }
        return String(afterMarker[..<endRange.lowerBound])
    }
}
