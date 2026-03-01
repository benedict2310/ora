//
//  ScriptManifestTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class ScriptManifestTests: XCTestCase {
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: self.rootDirectory.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func test_load_missingManifest_returnsDefaults() throws {
        let manifest = try ScriptManifest.load(from: self.rootDirectory)
        XCTAssertFalse(manifest.isPresent)

        let config = manifest.config(for: "test.py")
        XCTAssertEqual(config.timeout, 30)
        XCTAssertEqual(config.output, .text)
        XCTAssertFalse(config.declaredInManifest)
    }

    func test_load_manifest_parsesScriptMetadata() throws {
        let manifestURL = self.rootDirectory
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        try """
        {
          "scripts": {
            "fetch.py": {
              "description": "Fetch weather",
              "arguments": [{"name": "location", "type": "string", "required": true}],
              "output": "json",
              "timeout": 12,
              "capabilities": ["network"]
            }
          }
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let manifest = try ScriptManifest.load(from: self.rootDirectory)
        let config = manifest.config(for: "fetch.py")

        XCTAssertTrue(manifest.isPresent)
        XCTAssertEqual(config.description, "Fetch weather")
        XCTAssertEqual(config.arguments.first?.name, "location")
        XCTAssertEqual(config.output, .json)
        XCTAssertEqual(config.timeout, 12)
        XCTAssertTrue(config.capabilities.contains("network"))
    }
}
