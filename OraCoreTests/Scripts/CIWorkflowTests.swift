import XCTest

final class CIWorkflowTests: XCTestCase {
    private static let localRunnerGuard = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && vars.ORA_LOCAL_CI_PR != '' && format('{0}', github.event.pull_request.number) == vars.ORA_LOCAL_CI_PR"

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

    func test_ciRunnerRoutesOnlyOptedInSameRepositoryPR() throws {
        let workflow = try Self.readCIWorkflow()
        let expectedRunsOn = "runs-on: ${{ fromJSON(\(Self.localRunnerGuard) && '[\"self-hosted\",\"macOS\",\"ARM64\",\"ora-local-ci\"]' || '\"macos-26\"') }}"
        XCTAssertTrue(workflow.contains(expectedRunsOn), "PR numbers must be compared as strings, not coerced numbers or case-insensitive branch names.")
        XCTAssertEqual(workflow.components(separatedBy: Self.localRunnerGuard).count - 1, 1)
        XCTAssertFalse(workflow.contains("ORA_LOCAL_CI_BRANCH"))

        XCTAssertTrue(Self.usesLocalRunner(event: "pull_request", headRepository: "benedict2310/ora", number: 211, optIn: "211"))
        XCTAssertFalse(Self.usesLocalRunner(event: "push", headRepository: "benedict2310/ora", number: 211, optIn: "211"))
        XCTAssertFalse(Self.usesLocalRunner(event: "pull_request", headRepository: "attacker/ora", number: 211, optIn: "211"))
        XCTAssertFalse(Self.usesLocalRunner(event: "pull_request", headRepository: "benedict2310/ora", number: 212, optIn: "211"))
        for optIn in ["", "212", "0211", "211.0", "211 ", "2.11e2", "trusted"] {
            XCTAssertFalse(Self.usesLocalRunner(event: "pull_request", headRepository: "benedict2310/ora", number: 211, optIn: optIn), "Non-exact opt-in: \(optIn)")
        }
    }

    func test_ciUsesReadOnlyPermissionsAndPrivateCheckout() throws {
        let result = try Self.runRuby("""
            require "yaml"
            document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
            abort "permissions changed" unless document.fetch("permissions") == {"contents" => "read"}
            checkout = document.fetch("jobs").fetch("build-and-test").fetch("steps").find { |step| step["name"] == "Checkout" }
            abort "checkout action changed" unless checkout.fetch("uses") == "actions/checkout@v4"
            abort "checkout persists credentials" unless checkout.fetch("with") == {"persist-credentials" => false}
        """)
        XCTAssertEqual(result.status, 0, result.output)
    }

    func test_workflowUsesEnvironmentSpecificSetup() throws {
        let workflow = try Self.readCIWorkflow()
        XCTAssertTrue(workflow.contains("command -v xcodegen"))
        XCTAssertTrue(workflow.contains("DEVELOPER_DIR=\"$developer_dir\" xcodebuild -version"))
        XCTAssertTrue(workflow.contains("echo \"DEVELOPER_DIR=$developer_dir\" >> \"$GITHUB_ENV\""))
        XCTAssertTrue(workflow.contains("Gem::Version.new(version) >= Gem::Version.new(\"26.0.1\")"))
        XCTAssertFalse(workflow.contains("workflow_dispatch:"))
        XCTAssertFalse(workflow.contains("config.sh --ephemeral"))
        let result = try Self.runRuby("""
            require "yaml"
            steps = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false).fetch("jobs").fetch("build-and-test").fetch("steps")
            ["Install XcodeGen", "Select Xcode 26.2"].each do |name|
              step = steps.find { |candidate| candidate["name"] == name }
              abort "hosted setup condition changed" unless step.fetch("if") == "${{ runner.environment == 'github-hosted' }}"
            end
            abort "hosted install changed" unless steps.find { |step| step["name"] == "Install XcodeGen" }.fetch("run") == "brew install xcodegen"
            abort "hosted Xcode pin changed" unless steps.find { |step| step["name"] == "Select Xcode 26.2" }.fetch("run") == "sudo xcode-select -s /Applications/Xcode_26.2.app"
            local = steps.find { |step| step["name"] == "Verify local XcodeGen and Xcode" }
            abort "local setup condition changed" unless local.fetch("if") == "${{ runner.environment == 'self-hosted' }}"
            abort "local setup mutates machine" if local.fetch("run").match?(/sudo|brew install|xcode-select -s/)
        """)
        XCTAssertEqual(result.status, 0, result.output)
    }

    func test_workflowIsValidYamlAndKeepsBuildTestStructure() throws {
        let result = try Self.runRuby("""
            require "yaml"
            document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
            events = document.fetch("on", document[true])
            abort "triggers changed" unless events == {"push" => {"branches" => ["main"]}, "pull_request" => {"branches" => ["main"]}}
            abort "job set changed" unless document.fetch("jobs").keys == ["build-and-test"]
            job = document.fetch("jobs").fetch("build-and-test")
            abort "job name changed" unless job.fetch("name") == "Build & Test"
            steps = job.fetch("steps")
            abort "build gate missing" unless steps.find { |step| step["name"] == "Build" }.fetch("run").include?("xcodebuild build")
            abort "test gate changed" unless steps.find { |step| step["name"] == "Test" }.fetch("run") == "./build.sh test"
            parser = steps.find { |step| step["name"] == "Parse test results" }
            abort "result gate changed" unless parser.fetch("if") == "always()" && parser.fetch("run") == "python3 scripts/xcresult_summary.py .artifacts/TestResults.xcresult"
        """)
        XCTAssertEqual(result.status, 0, result.output)
    }

    func test_ciAndBuildUseLockedPackageResolution() throws {
        let result = try Self.runRuby("""
            require "yaml"
            steps = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false).fetch("jobs").fetch("build-and-test").fetch("steps")
            copy = steps.index { |step| step["name"] == "Copy tracked package resolution" }
            abort "lock copy step missing" unless copy
            abort "lock copied before generation" unless copy > steps.index { |step| step["name"] == "Generate Xcode project" }
            abort "lock copied after resolution" unless copy < steps.index { |step| step["name"] == "Resolve packages" }
            destination = "Ora.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
            copy_script = steps[copy].fetch("run")
            abort "required lock is not copied" unless copy_script.include?("test -f Package.resolved") && copy_script.include?("cp Package.resolved " + destination + "/Package.resolved")
            ["Resolve packages", "Build"].each do |name|
              abort "unlocked CI gate" unless steps.find { |step| step["name"] == name }.fetch("run").include?("-onlyUsePackageVersionsFromResolvedFile")
            end
            cache = steps.find { |step| step["name"] == "Cache SPM packages" }
            abort "cache ignores lock" unless cache.fetch("with").fetch("key").include?("'Package.resolved'")
        """)
        XCTAssertEqual(result.status, 0, result.output)

        let buildScript = try String(contentsOf: Self.repoRoot.appendingPathComponent("build.sh"), encoding: .utf8)
        let logicalLines = buildScript.replacingOccurrences(of: "\\\n", with: " ")
        let commands = try NSRegularExpression(pattern: #"(?m)^[ \t]*(?:ORA_SKIP_PERMISSION_PROMPTS="\$skip_prompts" )?xcodebuild[^\n]*"#)
            .matches(in: logicalLines, range: NSRange(logicalLines.startIndex..., in: logicalLines))
        XCTAssertEqual(commands.count, 4, "All test, build, retry and signing-build invocations must be checked.")
        for command in commands {
            let range = try XCTUnwrap(Range(command.range, in: logicalLines))
            XCTAssertTrue(logicalLines[range].contains("-onlyUsePackageVersionsFromResolvedFile"), "Unlocked xcodebuild invocation: \(logicalLines[range])")
        }
    }

    private static func usesLocalRunner(event: String, headRepository: String, number: Int, optIn: String) -> Bool {
        event == "pull_request" && headRepository.lowercased() == "benedict2310/ora" && !optIn.isEmpty && String(number) == optIn
    }

    private static func runRuby(_ script: String) throws -> (status: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["-e", script, Self.repoRoot.appendingPathComponent(".github/workflows/ci.yml").path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func readCIWorkflow() throws -> String {
        try String(contentsOf: self.repoRoot.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
    }
}
