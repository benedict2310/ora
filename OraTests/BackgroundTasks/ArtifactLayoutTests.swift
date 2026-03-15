//
//  ArtifactLayoutTests.swift
//  OraTests
//
//  Tests for deterministic artifact path layout and slug sanitization.
//

import XCTest
@testable import Ora

final class ArtifactLayoutTests: XCTestCase {

    func test_layout_buildsExpectedTaskPath() throws {
        let rootURL = try self.makeTemporaryRootURL()
        let layout = try ArtifactLayout(rootURL: rootURL)
        let task = self.makeSnapshot(
            id: UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!,
            label: "Plan Demo Launch",
            urls: ["https://example.com/research/demo"],
            createdAt: Self.fixtureDate
        )

        let directoryURL = try layout.taskDirectoryURL(for: task)

        XCTAssertEqual(
            directoryURL.path,
            rootURL
                .appendingPathComponent("2026-01-02", isDirectory: true)
                .appendingPathComponent("task-12345678-plan-demo-launch", isDirectory: true)
                .path
        )
    }

    func test_slug_sanitizesUnsafeCharacters() throws {
        let rootURL = try self.makeTemporaryRootURL()
        let layout = try ArtifactLayout(rootURL: rootURL)
        let task = self.makeSnapshot(
            label: "Quarterly Report ../ Launch / 2026!!!",
            urls: ["https://example.com/research"],
            createdAt: Self.fixtureDate
        )

        let slug = layout.slug(for: task)

        XCTAssertEqual(slug, "quarterly-report-launch-2026")
        XCTAssertFalse(slug.contains("/"))
        XCTAssertFalse(slug.contains(".."))
    }

    func test_slug_rejectsPathTraversal() throws {
        let rootURL = try self.makeTemporaryRootURL()
        let layout = try ArtifactLayout(rootURL: rootURL)
        let task = self.makeSnapshot(
            label: "../../../../../tmp/evil",
            urls: ["https://example.com/research"],
            createdAt: Self.fixtureDate
        )

        let directoryURL = try layout.taskDirectoryURL(for: task)

        XCTAssertTrue(directoryURL.path.hasPrefix(rootURL.path + "/"))
        XCTAssertFalse(directoryURL.lastPathComponent.contains(".."))
        XCTAssertFalse(directoryURL.path.contains("/../"))
    }

    // MARK: - Helpers

    private func makeSnapshot(
        id: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        label: String?,
        urls: [String],
        createdAt: Date
    ) -> BackgroundTaskRecordSnapshot {
        return BackgroundTaskRecordSnapshot(
            id: id,
            taskKind: "research",
            inputs: BackgroundTaskInputs(urls: urls, label: label),
            policy: BackgroundTaskPolicy(),
            state: .queued,
            summaryState: nil,
            artifactPath: nil,
            errorMessage: nil,
            createdAt: createdAt,
            startedAt: nil,
            completedAt: nil,
            sessionID: nil
        )
    }

    private func makeTemporaryRootURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private static let fixtureDate = ISO8601DateFormatter().date(from: "2026-01-02T10:30:00Z")!
}
