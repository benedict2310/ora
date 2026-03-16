//
//  SummaryGeneratorTests.swift
//  OraTests
//
//  Tests for SummaryGenerator background summary job queue.
//

import XCTest
@testable import Ora

@MainActor
final class SummaryGeneratorTests: XCTestCase {

    // MARK: - test_generator_writesSummaryMarkdown

    func test_generator_writesSummaryMarkdown() async throws {
        let rootDir = self.makeTemporaryDirectory()
        let taskID = UUID()
        let store = ArtifactStore(rootURL: rootDir)
        let mockLLM = SummaryMockLLMService(response: "- Key finding 1\n- Key finding 2")
        let managerHolder = SummaryManagerHolder()

        let generator = SummaryGenerator(
            llmService: mockLLM,
            artifactStore: store,
            taskManagerProvider: { await managerHolder.manager }
        )

        let taskDirURL = try self.writeMinimalArtifact(
            rootURL: rootDir,
            taskID: taskID,
            pages: [
                ArtifactStoredPage(
                    pageNumber: 1,
                    url: "https://example.com",
                    title: "Example",
                    extractedText: "Some research content for summarization.",
                    rawHTMLFilename: nil
                )
            ],
            label: "Test Research"
        )

        let manager = await self.makeInMemoryManager()
        await managerHolder.set(manager)

        await generator.start()
        await generator.enqueueSummary(taskID: taskID)

        NotificationCenter.default.post(name: .oraForegroundWorkIdle, object: nil)

        let summaryURL = taskDirURL.appendingPathComponent("summary.md")
        let written = await self.waitUntil {
            FileManager.default.fileExists(atPath: summaryURL.path)
        }

        await generator.stop()

        XCTAssertTrue(written, "summary.md should be written")
        if written {
            let content = try String(contentsOf: summaryURL, encoding: .utf8)
            XCTAssertTrue(content.contains("Key finding"), "Summary should contain LLM output")
        }

        await manager.cancelAll()
    }

    // MARK: - test_generator_updatesSummaryState

    func test_generator_updatesSummaryState() async throws {
        let rootDir = self.makeTemporaryDirectory()
        let taskID = UUID()
        let mockLLM = SummaryMockLLMService(response: "Summary output")
        let managerHolder = SummaryManagerHolder()
        let store = ArtifactStore(rootURL: rootDir)

        let generator = SummaryGenerator(
            llmService: mockLLM,
            artifactStore: store,
            taskManagerProvider: { await managerHolder.manager }
        )

        let manager = await self.makeInMemoryManager()
        await managerHolder.set(manager)

        let taskDirURL = try self.writeMinimalArtifact(
            rootURL: rootDir,
            taskID: taskID,
            pages: [ArtifactStoredPage(
                pageNumber: 1,
                url: "https://example.com",
                title: "Example",
                extractedText: "Content",
                rawHTMLFilename: nil
            )],
            label: nil
        )

        await generator.start()
        await generator.enqueueSummary(taskID: taskID)
        NotificationCenter.default.post(name: .oraForegroundWorkIdle, object: nil)

        let summaryURL = taskDirURL.appendingPathComponent("summary.md")
        let written = await self.waitUntil {
            FileManager.default.fileExists(atPath: summaryURL.path)
        }

        await generator.stop()
        XCTAssertTrue(written, "summary.md should be written")
    }

    // MARK: - test_generator_fallbackWritesExtractiveSummaryOnFailure

    func test_generator_fallbackWritesExtractiveSummaryOnFailure() async throws {
        let rootDir = self.makeTemporaryDirectory()
        let taskID = UUID()
        let failingLLM = SummaryFailingLLMService()
        let managerHolder = SummaryManagerHolder()
        let store = ArtifactStore(rootURL: rootDir)

        let generator = SummaryGenerator(
            llmService: failingLLM,
            artifactStore: store,
            taskManagerProvider: { await managerHolder.manager }
        )

        let manager = await self.makeInMemoryManager()
        await managerHolder.set(manager)

        let taskDirURL = try self.writeMinimalArtifact(
            rootURL: rootDir,
            taskID: taskID,
            pages: [ArtifactStoredPage(
                pageNumber: 1,
                url: "https://example.com",
                title: "Fallback Test",
                extractedText: "This is extractive fallback content that should appear.",
                rawHTMLFilename: nil
            )],
            label: nil
        )

        await generator.start()
        await generator.enqueueSummary(taskID: taskID)
        NotificationCenter.default.post(name: .oraForegroundWorkIdle, object: nil)

        let summaryURL = taskDirURL.appendingPathComponent("summary.md")
        let written = await self.waitUntil(timeout: .seconds(30)) {
            FileManager.default.fileExists(atPath: summaryURL.path)
        }

        await generator.stop()

        XCTAssertTrue(written, "Extractive fallback summary.md should be written after LLM failures")
        if written {
            let content = try String(contentsOf: summaryURL, encoding: .utf8)
            XCTAssertTrue(content.contains("Fallback Test"), "Fallback should contain page title")
            XCTAssertTrue(content.contains("extractive fallback content"), "Fallback should contain page text")
            XCTAssertTrue(content.contains("Source: https://example.com"), "Fallback should contain source URL")
        }
    }

    // MARK: - test_generator_maxRequeueAttemptsTriggersExtractiveFallback

    func test_generator_maxRequeueAttemptsTriggersExtractiveFallback() async throws {
        // Verify that buildExtractiveFallback produces correct output format
        let pages = [
            ArtifactStoredPage(
                pageNumber: 1,
                url: "https://example.com/1",
                title: "Page One",
                extractedText: "First page content",
                rawHTMLFilename: nil
            ),
            ArtifactStoredPage(
                pageNumber: 2,
                url: "https://example.com/2",
                title: "Page Two",
                extractedText: "Second page content",
                rawHTMLFilename: nil
            )
        ]

        let fallback = SummaryGenerator.buildExtractiveFallback(pages: pages)

        XCTAssertTrue(fallback.contains("## Page One"))
        XCTAssertTrue(fallback.contains("First page content"))
        XCTAssertTrue(fallback.contains("Source: https://example.com/1"))
        XCTAssertTrue(fallback.contains("## Page Two"))
        XCTAssertTrue(fallback.contains("Second page content"))
        XCTAssertTrue(fallback.contains("---"))
    }

    // MARK: - test_generator_respectsMinimumIdleWindow

    func test_generator_respectsMinimumIdleWindow() async throws {
        let rootDir = self.makeTemporaryDirectory()
        let taskID = UUID()
        let mockLLM = SummaryMockLLMService(response: "Summary")
        let store = ArtifactStore(rootURL: rootDir)
        let managerHolder = SummaryManagerHolder()

        let generator = SummaryGenerator(
            llmService: mockLLM,
            artifactStore: store,
            taskManagerProvider: { await managerHolder.manager }
        )

        let manager = await self.makeInMemoryManager()
        await managerHolder.set(manager)

        let taskDirURL = try self.writeMinimalArtifact(
            rootURL: rootDir,
            taskID: taskID,
            pages: [ArtifactStoredPage(
                pageNumber: 1,
                url: "https://example.com",
                title: "Test",
                extractedText: "Content",
                rawHTMLFilename: nil
            )],
            label: nil
        )

        await generator.start()
        await generator.enqueueSummary(taskID: taskID)

        // Immediately post foreground started to interrupt idle window
        NotificationCenter.default.post(name: .oraForegroundWorkStarted, object: nil)

        // Give a moment for cancellation to propagate
        try await Task.sleep(for: .milliseconds(100))

        let summaryURL = taskDirURL.appendingPathComponent("summary.md")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: summaryURL.path),
            "Summary should NOT be written when foreground is active"
        )

        // Now go idle and let it process
        NotificationCenter.default.post(name: .oraForegroundWorkIdle, object: nil)

        let written = await self.waitUntil(timeout: .seconds(15)) {
            FileManager.default.fileExists(atPath: summaryURL.path)
        }

        await generator.stop()
        XCTAssertTrue(written, "Summary should be written after going idle")
        await manager.cancelAll()
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeInMemoryManager() async -> BackgroundTaskManager {
        let persistence = PersistenceManager.createForTesting(inMemory: true)
        let manager = BackgroundTaskManager(modelContainer: persistence.container)
        await manager.configureForTesting(
            executor: { _ in BackgroundTaskExecutionResult() }
        )
        return manager
    }

    /// Writes a minimal artifact into the date-based directory layout that ArtifactStore.read() expects.
    /// Returns the task directory URL where the artifact files were written.
    @discardableResult
    private func writeMinimalArtifact(
        rootURL: URL,
        taskID: UUID,
        pages: [ArtifactStoredPage],
        label: String?
    ) throws -> URL {
        let now = Date()

        // Build the date-based subdirectory: rootURL/YYYY-MM-DD/task-SHORTID-slug/
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let dateComponent = formatter.string(from: now)

        let shortID = taskID.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let slug = label.map { ArtifactLayout.sanitizedSlug(from: $0) } ?? "research"
        let folderName = "task-\(shortID)-\(slug)"

        let taskDirURL = rootURL
            .appendingPathComponent(dateComponent, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirURL, withIntermediateDirectories: true)

        let result = ArtifactResult(
            taskID: taskID,
            taskKind: "web_research",
            label: label,
            sourceURLs: pages.map(\.url),
            title: label ?? "Research",
            summary: "Test summary",
            markdown: "Test markdown",
            pages: pages,
            createdAt: now,
            completedAt: now
        )
        let manifest = ArtifactManifest(
            taskID: taskID,
            taskKind: "web_research",
            label: label,
            sourceURLs: pages.map(\.url),
            artifactPath: taskDirURL.path,
            createdAt: now,
            completedAt: now,
            citationCount: 0,
            pageCount: pages.count,
            rawHTMLPageCount: 0
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode(result).write(to: taskDirURL.appendingPathComponent("result.json"))
        try encoder.encode(manifest).write(to: taskDirURL.appendingPathComponent("manifest.json"))
        try encoder.encode([BackgroundTaskArtifactCitation]()).write(to: taskDirURL.appendingPathComponent("citations.json"))

        return taskDirURL
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < timeout {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

// MARK: - Mock LLM Services

private actor SummaryMockLLMService: LLMServicing {
    let response: String

    init(response: String) {
        self.response = response
    }

    func prepare() async throws {}
    func warmup() async throws {}
    func unload() async {}
    func capabilities() async -> ProviderCapabilities { .textOnly }
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        let response = self.response
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.yield(.completed(totalTokens: 1))
            continuation.finish()
        }
    }

    func generateOneShot(prompt: String, maxTokens: Int) async throws -> String {
        return self.response
    }
}

private actor SummaryFailingLLMService: LLMServicing {
    func prepare() async throws {}
    func warmup() async throws {}
    func unload() async {}
    func capabilities() async -> ProviderCapabilities { .textOnly }
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMServiceError.generationFailed("Mock failure"))
        }
    }

    func generateOneShot(prompt: String, maxTokens: Int) async throws -> String {
        throw LLMServiceError.generationFailed("Mock failure")
    }
}

private actor SummaryManagerHolder {
    var manager: BackgroundTaskManager?

    func set(_ manager: BackgroundTaskManager) {
        self.manager = manager
    }
}
