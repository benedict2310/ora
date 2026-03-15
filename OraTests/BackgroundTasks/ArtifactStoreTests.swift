//
//  ArtifactStoreTests.swift
//  OraTests
//
//  Tests for file-backed artifact persistence.
//

import XCTest
@testable import Ora

final class ArtifactStoreTests: XCTestCase {

    func test_save_writesResultAndCitationFiles() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let store = ArtifactStore(rootURL: rootURL)
        let task = self.makeSnapshot(
            id: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
            label: "Project Atlas",
            createdAt: Self.createdAt
        )

        let manifest = try await store.save(
            task: task,
            workerResult: Self.sampleWorkerResult(),
            persistRawHTML: false
        )

        let taskDirectoryURL = URL(fileURLWithPath: manifest.artifactPath, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskDirectoryURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskDirectoryURL.appendingPathComponent("result.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskDirectoryURL.appendingPathComponent("citations.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: taskDirectoryURL.appendingPathComponent("raw").path))
    }

    func test_save_optionallyWritesRawHTML() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let store = ArtifactStore(rootURL: rootURL)

        let manifest = try await store.save(
            task: self.makeSnapshot(label: "Raw Capture", createdAt: Self.createdAt),
            workerResult: Self.sampleWorkerResult(),
            persistRawHTML: true
        )

        let taskDirectoryURL = URL(fileURLWithPath: manifest.artifactPath, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskDirectoryURL.appendingPathComponent("raw/page-1.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskDirectoryURL.appendingPathComponent("raw/page-2.html").path))
    }

    func test_read_roundTripsSavedArtifact() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let store = ArtifactStore(rootURL: rootURL)
        let task = self.makeSnapshot(label: "Round Trip", createdAt: Self.createdAt)
        let workerResult = Self.sampleWorkerResult()

        _ = try await store.save(task: task, workerResult: workerResult, persistRawHTML: true)
        let artifact = try await store.read(taskID: task.id)

        XCTAssertEqual(artifact.manifest.taskID, task.id)
        XCTAssertEqual(artifact.result.summary, workerResult.summary)
        XCTAssertEqual(artifact.citations, workerResult.citations)
        XCTAssertEqual(artifact.rawHTMLPages.count, 2)
    }

    func test_list_returnsNewestFirst() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let olderStore = ArtifactStore(rootURL: rootURL, now: { Self.olderCompletedAt })
        let newerStore = ArtifactStore(rootURL: rootURL, now: { Self.newerCompletedAt })
        let listStore = ArtifactStore(rootURL: rootURL)

        let olderTask = self.makeSnapshot(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            label: "Older",
            createdAt: Self.createdAt
        )
        let newerTask = self.makeSnapshot(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            label: "Newer",
            createdAt: Self.createdAt.addingTimeInterval(60)
        )

        _ = try await olderStore.save(task: olderTask, workerResult: Self.sampleWorkerResult())
        _ = try await newerStore.save(task: newerTask, workerResult: Self.sampleWorkerResult())

        let manifests = await listStore.list(limit: 10)

        XCTAssertEqual(manifests.map(\.taskID), [newerTask.id, olderTask.id])
    }

    func test_revealInFinder_usesArtifactPath() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let recorder = RevealRecorder()
        let store = ArtifactStore(
            rootURL: rootURL,
            revealer: { url in
                await recorder.record(url)
            }
        )
        let task = self.makeSnapshot(label: "Reveal Me", createdAt: Self.createdAt)

        let manifest = try await store.save(task: task, workerResult: Self.sampleWorkerResult())
        try await store.revealInFinder(taskID: task.id)

        let revealedURL = await recorder.revealedURL()
        XCTAssertEqual(revealedURL?.path, manifest.artifactPath)
    }

    func test_cleanup_removesExpiredArtifactsOnly() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let oldStore = ArtifactStore(rootURL: rootURL, now: { Self.expiredCompletedAt })
        let currentStore = ArtifactStore(rootURL: rootURL, now: { Self.currentCompletedAt })
        let cleanupStore = ArtifactStore(rootURL: rootURL)
        let oldTask = self.makeSnapshot(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            label: "Expired",
            createdAt: Self.createdAt.addingTimeInterval(-90 * 24 * 60 * 60)
        )
        let currentTask = self.makeSnapshot(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            label: "Current",
            createdAt: Self.createdAt
        )

        let oldManifest = try await oldStore.save(task: oldTask, workerResult: Self.sampleWorkerResult())
        let currentManifest = try await currentStore.save(task: currentTask, workerResult: Self.sampleWorkerResult())

        let removedCount = await cleanupStore.cleanup(olderThan: Self.cleanupCutoff)

        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldManifest.artifactPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentManifest.artifactPath))
    }

    func test_save_rejectsSymlinkedDirectory() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let redirectedURL = try self.makeTemporaryRootURL()
        let dateDirectoryURL = rootURL.appendingPathComponent("2026-01-02", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: dateDirectoryURL, withDestinationURL: redirectedURL)

        let store = ArtifactStore(rootURL: rootURL)

        do {
            _ = try await store.save(
                task: self.makeSnapshot(label: "Symlinked", createdAt: Self.createdAt),
                workerResult: Self.sampleWorkerResult()
            )
            XCTFail("Expected symlink detection")
        } catch let error as ArtifactStoreError {
            XCTAssertEqual(error, .symlinkDetected(path: dateDirectoryURL.path))
        }
    }

    func test_save_usesAtomicWrites() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let recorder = AtomicWriteRecorder()
        let store = ArtifactStore(
            rootURL: rootURL,
            atomicWriteObserver: { tempURL, destinationURL in
                recorder.record(tempURL: tempURL, destinationURL: destinationURL)
            }
        )

        _ = try await store.save(
            task: self.makeSnapshot(label: "Atomic", createdAt: Self.createdAt),
            workerResult: Self.sampleWorkerResult()
        )

        let writes = recorder.writes()
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(Set(writes.map(\.destinationURL.lastPathComponent)), Set(["manifest.json", "result.json", "citations.json"]))
        XCTAssertTrue(writes.allSatisfy { $0.tempURL.deletingLastPathComponent() == $0.destinationURL.deletingLastPathComponent() })
        XCTAssertTrue(writes.allSatisfy { $0.tempURL.lastPathComponent.hasSuffix(".tmp") })
    }

    func test_diskQuota_refusesWriteWhenExceeded() async throws {
        let rootURL = try self.makeTemporaryRootURL()
        let oversizedFileURL = rootURL.appendingPathComponent("oversized.bin")
        try Data(repeating: 0xFF, count: 4_096).write(to: oversizedFileURL)
        let store = ArtifactStore(rootURL: rootURL, diskQuotaBytes: 1_024)
        let task = self.makeSnapshot(label: "Quota", createdAt: Self.createdAt)

        do {
            _ = try await store.save(task: task, workerResult: Self.sampleWorkerResult())
            XCTFail("Expected quota enforcement")
        } catch let error as ArtifactStoreError {
            switch error {
            case .diskQuotaExceeded(let limitBytes, _, _):
                XCTAssertEqual(limitBytes, 1_024)
            default:
                XCTFail("Unexpected artifact store error: \(error)")
            }
        }

        let layout = try ArtifactLayout(rootURL: rootURL)
        let taskDirectoryURL = try layout.taskDirectoryURL(for: task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: taskDirectoryURL.path))
    }

    // MARK: - Helpers

    private func makeSnapshot(
        id: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        label: String?,
        createdAt: Date
    ) -> BackgroundTaskRecordSnapshot {
        return BackgroundTaskRecordSnapshot(
            id: id,
            taskKind: "research",
            inputs: BackgroundTaskInputs(urls: ["https://example.com/research"], label: label),
            policy: BackgroundTaskPolicy(),
            state: .running,
            summaryState: nil,
            artifactPath: nil,
            errorMessage: nil,
            createdAt: createdAt,
            startedAt: createdAt,
            completedAt: nil,
            sessionID: nil
        )
    }

    private func makeTemporaryRootURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private static func sampleWorkerResult() -> BackgroundTaskWorkerResult {
        return BackgroundTaskWorkerResult(
            title: "Project Atlas Research",
            summary: "Two sources agree on the launch timeline.",
            markdown: "- Source A confirms launch.\n- Source B confirms dependencies.",
            pages: [
                BackgroundTaskArtifactPage(
                    pageNumber: 1,
                    url: "https://example.com/source-a",
                    title: "Source A",
                    extractedText: "Launch is scheduled for Q2.",
                    rawHTML: "<html><body>Source A</body></html>"
                ),
                BackgroundTaskArtifactPage(
                    pageNumber: 2,
                    url: "https://example.com/source-b",
                    title: "Source B",
                    extractedText: "Dependencies are already approved.",
                    rawHTML: "<html><body>Source B</body></html>"
                )
            ],
            citations: [
                BackgroundTaskArtifactCitation(
                    url: "https://example.com/source-a",
                    title: "Source A",
                    snippet: "Launch is scheduled for Q2."
                ),
                BackgroundTaskArtifactCitation(
                    url: "https://example.com/source-b",
                    title: "Source B",
                    snippet: "Dependencies are already approved."
                )
            ]
        )
    }

    private static let createdAt = ISO8601DateFormatter().date(from: "2026-01-02T10:30:00Z")!
    private static let olderCompletedAt = ISO8601DateFormatter().date(from: "2026-01-05T08:00:00Z")!
    private static let newerCompletedAt = ISO8601DateFormatter().date(from: "2026-01-06T08:00:00Z")!
    private static let expiredCompletedAt = ISO8601DateFormatter().date(from: "2025-12-01T08:00:00Z")!
    private static let currentCompletedAt = ISO8601DateFormatter().date(from: "2026-01-20T08:00:00Z")!
    private static let cleanupCutoff = ISO8601DateFormatter().date(from: "2025-12-31T00:00:00Z")!
}

private actor RevealRecorder {
    private var storedURL: URL?

    func record(_ url: URL) {
        self.storedURL = url
    }

    func revealedURL() -> URL? {
        return self.storedURL
    }
}

private final class AtomicWriteRecorder: @unchecked Sendable {
    private var storedWrites: [AtomicWriteRecord] = []
    private let lock = NSLock()

    func record(tempURL: URL, destinationURL: URL) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storedWrites.append(AtomicWriteRecord(tempURL: tempURL, destinationURL: destinationURL))
    }

    func writes() -> [AtomicWriteRecord] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storedWrites
    }
}

private struct AtomicWriteRecord: Sendable, Equatable {
    let tempURL: URL
    let destinationURL: URL
}
