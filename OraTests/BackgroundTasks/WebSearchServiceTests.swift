//
//  WebSearchServiceTests.swift
//  OraTests
//
//  Tests for DuckDuckGo HTML Lite result discovery.
//

import XCTest
@testable import Ora

final class WebSearchServiceTests: XCTestCase {

    func test_parsesHTMLLiteResults() async throws {
        let html = """
        <html><body>
          <a class="result__a" href="https://example.com/article">Example</a>
          <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Freport">Tracked</a>
          <a class="result__url" href="https://example.net/overview">Visible URL</a>
        </body></html>
        """
        let fetchClient = SearchStubFetchClient(html: html)
        let service = WebSearchService(fetchClient: fetchClient)

        let result = try await service.search(
            query: "latest Ora research",
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.searchQuery, "latest Ora research")
        XCTAssertEqual(
            result.urls.map(\.absoluteString),
            [
                "https://example.com/article",
                "https://example.org/report",
                "https://example.net/overview"
            ]
        )

        let request = await fetchClient.lastRequest()
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.absoluteString, "https://html.duckduckgo.com/html/")
    }

    func test_deduplicatesByDomain() async throws {
        let html = """
        <html><body>
          <a class="result__a" href="https://example.com/one">One</a>
          <a class="result__a" href="https://www.example.com/two">Two</a>
          <a class="result__a" href="https://example.org/three">Three</a>
        </body></html>
        """
        let service = WebSearchService(fetchClient: SearchStubFetchClient(html: html))

        let result = try await service.search(query: "dedupe", policy: BackgroundTaskPolicy())

        XCTAssertEqual(
            result.urls.map(\.absoluteString),
            [
                "https://example.com/one",
                "https://example.org/three"
            ]
        )
    }

    func test_respectsMaxResultLimit() async throws {
        let html = """
        <html><body>
          <a class="result__a" href="https://one.example.com/a">One</a>
          <a class="result__a" href="https://two.example.com/b">Two</a>
          <a class="result__a" href="https://three.example.com/c">Three</a>
        </body></html>
        """
        let service = WebSearchService(fetchClient: SearchStubFetchClient(html: html))

        let result = try await service.search(
            query: "limit",
            maxResults: 2,
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(result.urls.count, 2)
        XCTAssertEqual(
            result.urls.map(\.absoluteString),
            [
                "https://one.example.com/a",
                "https://two.example.com/b"
            ]
        )
    }

    func test_filtersInternalDDGLinks() async throws {
        let html = """
        <html><body>
          <a class="result__a" href="https://duckduckgo.com/about">Internal</a>
          <a class="result__a" href="https://www.duck.co/help">Duck</a>
          <a class="result__a" href="https://example.com/public">External</a>
        </body></html>
        """
        let service = WebSearchService(fetchClient: SearchStubFetchClient(html: html))

        let result = try await service.search(query: "filter", policy: BackgroundTaskPolicy())

        XCTAssertEqual(result.urls.map(\.absoluteString), ["https://example.com/public"])
    }

    func test_handlesEmptyResults() async throws {
        let html = "<html><body><p>No results</p></body></html>"
        let service = WebSearchService(fetchClient: SearchStubFetchClient(html: html))

        let result = try await service.search(query: "nothing", policy: BackgroundTaskPolicy())

        XCTAssertTrue(result.urls.isEmpty)
    }

    func test_handlesTrackingRedirects() async throws {
        let html = """
        <html><body>
          <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fwhitepaper%3Fref%3Dora">Tracked</a>
        </body></html>
        """
        let service = WebSearchService(fetchClient: SearchStubFetchClient(html: html))

        let result = try await service.search(query: "tracking", policy: BackgroundTaskPolicy())

        XCTAssertEqual(result.urls.map(\.absoluteString), ["https://example.com/whitepaper?ref=ora"])
    }

    func test_validatesDiscoveredURLSchemes() async throws {
        let html = """
        <html><body>
          <a class="result__a" href="javascript:alert(1)">JS</a>
          <a class="result__a" href="file:///etc/passwd">File</a>
          <a class="result__a" href="https://example.com/allowed">Allowed</a>
          <a class="result__a" href="//duckduckgo.com/l/?uddg=file%3A%2F%2F%2Ftmp%2Fbad">Tracked File</a>
        </body></html>
        """
        let service = WebSearchService(fetchClient: SearchStubFetchClient(html: html))

        let result = try await service.search(query: "schemes", policy: BackgroundTaskPolicy())

        XCTAssertEqual(result.urls.map(\.absoluteString), ["https://example.com/allowed"])
    }
}

private actor SearchStubFetchClient: WorkerFetchClient {
    private let response: FetchedPageResponse
    private var recordedRequest: URLRequest?

    init(html: String) {
        self.response = FetchedPageResponse(
            finalURL: URL(string: "https://html.duckduckgo.com/html/")!,
            statusCode: 200,
            contentType: "text/html; charset=utf-8",
            textEncodingName: "utf-8",
            body: Data(html.utf8),
            fetchedAt: Date()
        )
    }

    func fetch(request: URLRequest, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        _ = policy
        self.recordedRequest = request
        return self.response
    }

    func lastRequest() -> URLRequest? {
        return self.recordedRequest
    }
}
