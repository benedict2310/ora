//
//  SkillPathSandboxTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillPathSandboxTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillPathSandboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("references", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func test_resolve_referencesPath_returnsResolvedURL() throws {
        let resolved = try SkillPathSandbox.resolve(root: tempDirectory, relativePath: "references/guide.md")
        XCTAssertTrue(resolved.path.hasSuffix("references/guide.md"))
    }

    func test_resolve_assetsPath_returnsResolvedURL() throws {
        let resolved = try SkillPathSandbox.resolve(root: tempDirectory, relativePath: "assets/icon.png")
        XCTAssertTrue(resolved.path.hasSuffix("assets/icon.png"))
    }

    func test_resolve_withTraversal_throwsInvalidPath() {
        XCTAssertThrowsError(try SkillPathSandbox.resolve(root: tempDirectory, relativePath: "references/../secrets.txt")) { error in
            guard case SkillError.invalidPath = error else {
                return XCTFail("Expected invalidPath")
            }
        }
    }

    func test_resolve_withDisallowedPrefix_throwsInvalidPath() {
        XCTAssertThrowsError(try SkillPathSandbox.resolve(root: tempDirectory, relativePath: "scripts/run.sh")) { error in
            guard case SkillError.invalidPath = error else {
                return XCTFail("Expected invalidPath")
            }
        }
    }

    func test_resolve_absolutePath_throwsInvalidPath() {
        XCTAssertThrowsError(try SkillPathSandbox.resolve(root: tempDirectory, relativePath: "/etc/passwd")) { error in
            guard case SkillError.invalidPath = error else {
                return XCTFail("Expected invalidPath")
            }
        }
    }
}
