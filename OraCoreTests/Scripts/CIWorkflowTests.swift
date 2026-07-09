import XCTest

final class CIWorkflowTests: XCTestCase {
    func test_ciTestStepUsesBuildScriptFastGate() throws {
        let workflow = try Self.readCIWorkflow()

        XCTAssertTrue(
            workflow.contains("./build.sh test"),
            "CI must run ./build.sh test so the repository default gate and GitHub PR gate stay aligned."
        )
        XCTAssertFalse(
            workflow.contains("xcodebuild test"),
            "CI should not bypass build.sh with a direct legacy xcodebuild test invocation."
        )
    }

    private static func readCIWorkflow() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // CIWorkflowTests.swift -> Scripts
            .deletingLastPathComponent() // Scripts -> OraCoreTests
            .deletingLastPathComponent() // OraCoreTests -> repository root
        let workflowURL = repoRoot
            .appendingPathComponent(".github")
            .appendingPathComponent("workflows")
            .appendingPathComponent("ci.yml")
        return try String(contentsOf: workflowURL, encoding: .utf8)
    }
}
