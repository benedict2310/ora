//
//  URLSessionWorkerQueryTests.swift
//  OraTests
//
//  Tests for query-driven URL discovery in URLSessionWorker.
//

import XCTest
@testable import Ora

final class URLSessionWorkerQueryTests: XCTestCase {

    func test_discoversURLsFromQuery() async throws {
        let discoveredURLs = [
            URL(string: "https://example.com/article")!,
            URL(string: "https://example.org/report")!
        ]
        let fetchClient = QueryRecordingFetchClient(
            plans: [
                "https://example.com/article": .success(Self.htmlResponse(url: "https://example.com/article", title: "Article", body: "Alpha")),
                "https://example.org/report": .success(Self.htmlResponse(url: "https://example.org/report", title: "Report", body: "Beta"))
            ]
        )
        let searchService = StubWebSearchService(
            result: .success(WebSearchResult(urls: discoveredURLs, searchQuery: "ora local AI"))
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(query: "ora local AI"),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.metadata.requestedURLCount, 2)
        XCTAssertEqual(result.pages.count, 2)
        let requestedURLs = await fetchClient.requestedURLs()
        XCTAssertEqual(
            requestedURLs,
            [
                "https://example.com/article",
                "https://example.org/report"
            ]
        )
        let recordedQueries = await searchService.recordedQueries()
        XCTAssertEqual(recordedQueries, ["ora local AI"])
    }

    func test_mergesQueryURLsWithExplicit() async throws {
        let explicitURL = "https://docs.ora.app/guide"
        let discoveredURLs = [
            URL(string: explicitURL)!,
            URL(string: "https://example.com/blog")!
        ]
        let fetchClient = QueryRecordingFetchClient(
            plans: [
                explicitURL: .success(Self.htmlResponse(url: explicitURL, title: "Guide", body: "Docs")),
                "https://example.com/blog": .success(Self.htmlResponse(url: "https://example.com/blog", title: "Blog", body: "News"))
            ]
        )
        let searchService = StubWebSearchService(
            result: .success(WebSearchResult(urls: discoveredURLs, searchQuery: "ora guide"))
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: [explicitURL], query: "ora guide"),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.metadata.requestedURLCount, 2)
        let requestedURLs = await fetchClient.requestedURLs()
        XCTAssertEqual(
            requestedURLs,
            [
                explicitURL,
                "https://example.com/blog"
            ]
        )
    }

    func test_mixedQueryCapsDiscoveredURLsToRemainingBudget() async throws {
        let explicitURLs = [
            "https://docs.ora.app/one",
            "https://docs.ora.app/two",
            "https://docs.ora.app/three",
            "https://docs.ora.app/four",
            "https://docs.ora.app/five",
            "https://docs.ora.app/six",
            "https://docs.ora.app/seven"
        ]
        let discoveredURLs = [
            URL(string: "https://example.com/a")!,
            URL(string: "https://example.org/b")!,
            URL(string: "https://example.net/c")!,
            URL(string: "https://example.edu/d")!
        ]
        let fetchClient = QueryRecordingFetchClient(
            plans: [
                "https://docs.ora.app/one": .success(Self.htmlResponse(url: "https://docs.ora.app/one", title: "One", body: "One")),
                "https://docs.ora.app/two": .success(Self.htmlResponse(url: "https://docs.ora.app/two", title: "Two", body: "Two")),
                "https://docs.ora.app/three": .success(Self.htmlResponse(url: "https://docs.ora.app/three", title: "Three", body: "Three")),
                "https://docs.ora.app/four": .success(Self.htmlResponse(url: "https://docs.ora.app/four", title: "Four", body: "Four")),
                "https://docs.ora.app/five": .success(Self.htmlResponse(url: "https://docs.ora.app/five", title: "Five", body: "Five")),
                "https://docs.ora.app/six": .success(Self.htmlResponse(url: "https://docs.ora.app/six", title: "Six", body: "Six")),
                "https://docs.ora.app/seven": .success(Self.htmlResponse(url: "https://docs.ora.app/seven", title: "Seven", body: "Seven")),
                "https://example.com/a": .success(Self.htmlResponse(url: "https://example.com/a", title: "A", body: "A")),
                "https://example.org/b": .success(Self.htmlResponse(url: "https://example.org/b", title: "B", body: "B"))
            ]
        )
        let searchService = StubWebSearchService(
            result: .success(WebSearchResult(urls: discoveredURLs, searchQuery: "ora capped"))
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: explicitURLs, query: "ora capped"),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.metadata.requestedURLCount, 9)
        let requestedURLs = await fetchClient.requestedURLs()
        XCTAssertEqual(
            requestedURLs,
            [
                "https://docs.ora.app/one",
                "https://docs.ora.app/two",
                "https://docs.ora.app/three",
                "https://docs.ora.app/four",
                "https://docs.ora.app/five",
                "https://docs.ora.app/six",
                "https://docs.ora.app/seven",
                "https://example.com/a",
                "https://example.org/b"
            ]
        )
        let recordedMaxResults = await searchService.recordedMaxResults()
        XCTAssertEqual(recordedMaxResults, [2])
    }

    func test_mergesCaseDistinctURLsWithoutDroppingThem() async throws {
        let explicitURL = "https://example.com/API"
        let discoveredURLs = [
            URL(string: "https://example.com/api")!,
            URL(string: "https://example.org/report")!
        ]
        let fetchClient = QueryRecordingFetchClient(
            plans: [
                explicitURL: .success(Self.htmlResponse(url: explicitURL, title: "Upper", body: "Upper")),
                "https://example.com/api": .success(Self.htmlResponse(url: "https://example.com/api", title: "Lower", body: "Lower")),
                "https://example.org/report": .success(Self.htmlResponse(url: "https://example.org/report", title: "Report", body: "Report"))
            ]
        )
        let searchService = StubWebSearchService(
            result: .success(WebSearchResult(urls: discoveredURLs, searchQuery: "ora case"))
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: [explicitURL], query: "ora case"),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.metadata.requestedURLCount, 3)
        let requestedURLs = await fetchClient.requestedURLs()
        XCTAssertEqual(
            requestedURLs,
            [
                explicitURL,
                "https://example.com/api",
                "https://example.org/report"
            ]
        )
    }

    func test_buildsProvenanceFromSearch() async throws {
        let discoveredURLs = [
            URL(string: "https://www.example.com/article")!,
            URL(string: "https://example.org/report")!
        ]
        let fetchClient = QueryRecordingFetchClient(
            plans: [
                "https://www.example.com/article": .success(Self.htmlResponse(url: "https://www.example.com/article", title: "Article", body: "Alpha")),
                "https://example.org/report": .success(Self.htmlResponse(url: "https://example.org/report", title: "Report", body: "Beta"))
            ]
        )
        let searchService = StubWebSearchService(
            result: .success(WebSearchResult(urls: discoveredURLs, searchQuery: "ora provenance"))
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(query: "ora provenance"),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.provenance?.query, "ora provenance")
        XCTAssertEqual(result.provenance?.searchQueries, ["ora provenance"])
        XCTAssertEqual(result.provenance?.domainsUsed, ["example.com", "example.org"])
    }

    func test_queryWithEmptySearchResultsFails() async throws {
        let fetchClient = QueryRecordingFetchClient(plans: [:])
        let searchService = StubWebSearchService(
            result: .success(WebSearchResult(urls: [], searchQuery: "ora empty"))
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        do {
            _ = try await worker.execute(
                taskID: UUID(),
                input: BackgroundTaskInputs(query: "ora empty"),
                policy: BackgroundTaskPolicy()
            )
            XCTFail("Expected all-pages failure")
        } catch let error as WorkerError {
            switch error {
            case .allPagesFailed(let failures):
                XCTAssertEqual(failures.count, 1)
                XCTAssertTrue(failures.first?.url.hasPrefix("search://") == true)
                XCTAssertEqual(failures.first?.code, .fetchFailed)
                XCTAssertEqual(failures.first?.message, "Search returned no URLs.")
            }
        } catch {
            throw error
        }
    }

    func test_searchErrorWithExplicitURLsFallsBackGracefully() async throws {
        let fetchClient = QueryRecordingFetchClient(
            plans: [
                "https://docs.ora.app/page": .success(Self.htmlResponse(url: "https://docs.ora.app/page", title: "Page", body: "Content"))
            ]
        )
        let searchService = StubWebSearchService(
            result: .failure(.unavailable)
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        let result = try await worker.execute(
            taskID: UUID(),
            input: BackgroundTaskInputs(urls: ["https://docs.ora.app/page"], query: "some topic"),
            policy: BackgroundTaskPolicy()
        )

        // Should succeed using only the explicit URL
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.pages.first?.title, "Page")
        // No provenance since search failed
        XCTAssertNil(result.provenance)
    }

    func test_searchErrorWithNoExplicitURLsFails() async throws {
        let fetchClient = QueryRecordingFetchClient(plans: [:])
        let searchService = StubWebSearchService(
            result: .failure(.unavailable)
        )
        let worker = URLSessionWorker(fetchClient: fetchClient, webSearchService: searchService)

        do {
            _ = try await worker.execute(
                taskID: UUID(),
                input: BackgroundTaskInputs(query: "some topic"),
                policy: BackgroundTaskPolicy()
            )
            XCTFail("Expected all-pages failure")
        } catch let error as WorkerError {
            switch error {
            case .allPagesFailed(let failures):
                XCTAssertEqual(failures.count, 1)
                XCTAssertTrue(failures.first?.url.hasPrefix("search://") == true)
                XCTAssertEqual(failures.first?.code, .fetchFailed)
            }
        } catch {
            throw error
        }
    }

    // MARK: - Helpers

    private static func htmlResponse(url: String, title: String, body: String) -> FetchedPageResponse {
        let html = """
        <html>
          <head><title>\(title)</title></head>
          <body><p>\(body)</p></body>
        </html>
        """
        let parsedURL = URL(string: url)!
        return FetchedPageResponse(
            finalURL: parsedURL,
            statusCode: 200,
            contentType: "text/html",
            textEncodingName: "utf-8",
            body: Data(html.utf8),
            fetchedAt: Date()
        )
    }
}

private actor QueryRecordingFetchClient: WorkerFetchClient {
    private let plans: [String: QueryFetchPlan]
    private var recordedURLs: [String] = []

    init(plans: [String: QueryFetchPlan]) {
        self.plans = plans
    }

    func fetch(request: URLRequest, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        _ = policy
        guard let url = request.url else {
            throw QueryFetchError.offline
        }

        self.recordedURLs.append(url.absoluteString)

        guard let plan = self.plans[url.absoluteString] else {
            throw QueryFetchError.offline
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
}

private actor StubWebSearchService: WebSearchServicing {
    private let plan: QuerySearchPlan
    private var queries: [String] = []
    private var maxResultsValues: [Int] = []

    init(result: QuerySearchPlan) {
        self.plan = result
    }

    func search(
        query: String,
        maxResults: Int,
        policy: BackgroundTaskPolicy
    ) async throws -> WebSearchResult {
        _ = policy
        self.queries.append(query)
        self.maxResultsValues.append(maxResults)

        switch self.plan {
        case .success(let result):
            return WebSearchResult(
                urls: Array(result.urls.prefix(maxResults)),
                searchQuery: result.searchQuery
            )
        case .failure(let error):
            throw error
        }
    }

    func recordedQueries() -> [String] {
        return self.queries
    }

    func recordedMaxResults() -> [Int] {
        return self.maxResultsValues
    }
}

private enum QueryFetchPlan: Sendable {
    case success(FetchedPageResponse)
    case failure(QueryFetchError)
}

private enum QuerySearchPlan: Sendable {
    case success(WebSearchResult)
    case failure(QuerySearchError)
}

private enum QueryFetchError: Error, Sendable {
    case offline
}

private enum QuerySearchError: Error, Sendable {
    case unavailable
}
