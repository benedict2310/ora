//
//  URLSessionWorkerTests.swift
//  OraTests
//
//  Tests for sequential background URL fetching and page extraction.
//

import XCTest
@testable import Ora

final class URLSessionWorkerTests: XCTestCase {

    func test_execute_singleHTMLURL_returnsPageResult() async throws {
        let html = """
        <html>
          <head><title>Worker Test</title></head>
          <body><p>Hello <strong>world</strong>.</p></body>
        </html>
        """
        let fetchClient = StubFetchClient(
            plans: [
                "https://example.com/page": .success(
                    FetchedPageResponse(
                        finalURL: URL(string: "https://example.com/final")!,
                        statusCode: 200,
                        contentType: "text/html; charset=utf-8",
                        textEncodingName: "utf-8",
                        body: Data(html.utf8),
                        fetchedAt: Date(timeIntervalSince1970: 100)
                    )
                )
            ]
        )
        let worker = URLSessionWorker(fetchClient: fetchClient)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: ["https://example.com/page"]),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.failedURLs.isEmpty)
        XCTAssertEqual(result.metadata.requestedURLCount, 1)
        XCTAssertEqual(result.metadata.succeededURLCount, 1)
        XCTAssertTrue(result.metadata.processedSequentially)

        let page = try XCTUnwrap(result.pages.first)
        XCTAssertEqual(page.url, "https://example.com/page")
        XCTAssertEqual(page.finalURL, "https://example.com/final")
        XCTAssertEqual(page.title, "Worker Test")
        XCTAssertEqual(page.text, "Hello world.")
        XCTAssertEqual(page.contentType, "text/html")
        XCTAssertEqual(page.wordCount, 2)
        XCTAssertEqual(page.rawHTML, html)

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(WorkerResult.self, from: encoded)
        XCTAssertEqual(decoded, result)
    }

    func test_execute_singlePlainTextURL_returnsPageResult() async throws {
        let fetchClient = StubFetchClient(
            plans: [
                "https://example.com/text": .success(
                    FetchedPageResponse(
                        finalURL: URL(string: "https://example.com/text")!,
                        statusCode: 200,
                        contentType: "text/plain",
                        textEncodingName: "utf-8",
                        body: Data("line one\nline two\n".utf8),
                        fetchedAt: Date()
                    )
                )
            ]
        )
        let worker = URLSessionWorker(fetchClient: fetchClient)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: ["https://example.com/text"]),
            policy: BackgroundTaskPolicy()
        )

        let page = try XCTUnwrap(result.pages.first)
        XCTAssertNil(page.title)
        XCTAssertEqual(page.text, "line one\nline two")
        XCTAssertEqual(page.contentType, "text/plain")
        XCTAssertNil(page.rawHTML)
    }

    func test_execute_multipleURLs_returnsSequentialResults() async throws {
        let fetchClient = RecordingFetchClient(
            plans: [
                "https://example.com/1": .success(Self.htmlResponse(title: "One", body: "Alpha")),
                "https://example.com/2": .success(Self.htmlResponse(title: "Two", body: "Beta"))
            ],
            delay: .milliseconds(50)
        )
        let worker = URLSessionWorker(fetchClient: fetchClient)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: ["https://example.com/1", "https://example.com/2"]),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.pages.map(\.title), ["One", "Two"])
        let requestedURLs = await fetchClient.requestedURLs()
        XCTAssertEqual(requestedURLs, ["https://example.com/1", "https://example.com/2"])
        let maxConcurrentRequests = await fetchClient.maxConcurrentRequests()
        XCTAssertEqual(maxConcurrentRequests, 1)
    }

    func test_execute_partialFailure_keepsSuccessfulPages() async throws {
        let fetchClient = StubFetchClient(
            plans: [
                "https://example.com/good": .success(Self.htmlResponse(title: "Good", body: "Readable")),
                "https://example.com/bad": .failure(TestFetchError.offline)
            ]
        )
        let worker = URLSessionWorker(fetchClient: fetchClient)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: ["https://example.com/good", "https://example.com/bad"]),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.pages.first?.title, "Good")
        XCTAssertEqual(result.failedURLs.count, 1)
        XCTAssertEqual(result.failedURLs.first?.url, "https://example.com/bad")
        XCTAssertEqual(result.failedURLs.first?.code, .fetchFailed)
        XCTAssertEqual(result.metadata.failedURLCount, 1)
    }

    func test_execute_allFailures_throws() async throws {
        let fetchClient = StubFetchClient(
            plans: [
                "https://example.com/1": .failure(TestFetchError.offline),
                "https://example.com/2": .failure(TestFetchError.timeout)
            ]
        )
        let worker = URLSessionWorker(fetchClient: fetchClient)

        do {
            _ = try await worker.execute(
                taskID: UUID(),
                input: BackgroundTaskInputs(urls: ["https://example.com/1", "https://example.com/2"]),
                policy: BackgroundTaskPolicy()
            )
            XCTFail("Expected all-page failure")
        } catch let error as WorkerError {
            switch error {
            case .allPagesFailed(let failures):
                XCTAssertEqual(failures.count, 2)
                XCTAssertEqual(failures.map(\.url), ["https://example.com/1", "https://example.com/2"])
            }
        } catch {
            throw error
        }
    }

    func test_execute_cancellationStopsRemainingFetches() async throws {
        let fetchClient = CancelOnSleepFetchClient()
        let worker = URLSessionWorker(fetchClient: fetchClient)

        let task = Task {
            try await worker.execute(
                taskID: UUID(),
                input: BackgroundTaskInputs(urls: ["https://example.com/1", "https://example.com/2"]),
                policy: BackgroundTaskPolicy()
            )
        }

        let reachedFirstURL = await self.waitUntil {
            let requestedURLs = await fetchClient.requestedURLs()
            return requestedURLs.count == 1
        }
        XCTAssertTrue(reachedFirstURL)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let urls = await fetchClient.requestedURLs()
            XCTAssertEqual(urls, ["https://example.com/1"])
        } catch {
            throw error
        }
    }

    // MARK: - Helpers

    private static func htmlResponse(title: String, body: String) -> FetchedPageResponse {
        let html = """
        <html>
          <head><title>\(title)</title></head>
          <body><p>\(body)</p></body>
        </html>
        """
        return FetchedPageResponse(
            finalURL: URL(string: "https://example.com/final-\(title.lowercased())")!,
            statusCode: 200,
            contentType: "text/html",
            textEncodingName: "utf-8",
            body: Data(html.utf8),
            fetchedAt: Date()
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < timeout {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private enum TestFetchError: Error, Sendable {
    case offline
    case timeout
}

private enum FetchPlan: Sendable {
    case success(FetchedPageResponse)
    case failure(TestFetchError)
}

private actor StubFetchClient: WorkerFetchClient {
    private let plans: [String: FetchPlan]

    init(plans: [String: FetchPlan]) {
        self.plans = plans
    }

    func fetch(url: URL, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        _ = policy
        guard let plan = self.plans[url.absoluteString] else {
            throw TestFetchError.offline
        }

        switch plan {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

private actor RecordingFetchClient: WorkerFetchClient {
    private let plans: [String: FetchPlan]
    private let delay: Duration
    private var recordedURLs: [String] = []
    private var concurrentRequests = 0
    private var highestConcurrentRequests = 0

    init(plans: [String: FetchPlan], delay: Duration) {
        self.plans = plans
        self.delay = delay
    }

    func fetch(url: URL, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        _ = policy
        self.recordedURLs.append(url.absoluteString)
        self.concurrentRequests += 1
        self.highestConcurrentRequests = max(self.highestConcurrentRequests, self.concurrentRequests)

        defer {
            self.concurrentRequests -= 1
        }

        try await Task.sleep(for: self.delay)
        guard let plan = self.plans[url.absoluteString] else {
            throw TestFetchError.offline
        }

        switch plan {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func requestedURLs() -> [String] {
        return self.recordedURLs
    }

    func maxConcurrentRequests() -> Int {
        return self.highestConcurrentRequests
    }
}

private actor CancelOnSleepFetchClient: WorkerFetchClient {
    private var recordedURLs: [String] = []

    func fetch(url: URL, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        _ = policy
        self.recordedURLs.append(url.absoluteString)
        try await Task.sleep(for: .seconds(5))
        return FetchedPageResponse(
            finalURL: url,
            statusCode: 200,
            contentType: "text/plain",
            textEncodingName: "utf-8",
            body: Data("done".utf8),
            fetchedAt: Date()
        )
    }

    func requestedURLs() -> [String] {
        return self.recordedURLs
    }
}
