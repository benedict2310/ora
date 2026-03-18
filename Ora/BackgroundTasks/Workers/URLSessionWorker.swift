//
//  URLSessionWorker.swift
//  Ora
//
//  Phase-1 in-process worker for sequential URL fetch and text extraction.
//

import Foundation
import CoreFoundation
import os

struct FetchedPageResponse: Sendable, Equatable {
    let finalURL: URL
    let statusCode: Int
    let contentType: String?
    let textEncodingName: String?
    let body: Data
    let fetchedAt: Date
}

protocol WorkerFetchClient: Sendable {
    func fetch(request: URLRequest, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse
}

extension WorkerFetchClient {
    func fetch(url: URL, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await self.fetch(request: request, policy: policy)
    }
}

struct URLSessionWorker: BackgroundWorker {

    // MARK: - Properties

    private let fetchClient: any WorkerFetchClient
    private let extractor: HTMLTextExtractor
    private let webSearchService: any WebSearchServicing
    private let maxRequests: Int
    private let logger = Logger.ora(category: "orchestration")

    // MARK: - Init

    init(
        fetchClient: any WorkerFetchClient = SafeURLSession(),
        extractor: HTMLTextExtractor = HTMLTextExtractor(),
        webSearchService: (any WebSearchServicing)? = nil,
        maxRequests: Int = NetworkSafetyPolicy.defaultMaxRequests
    ) {
        self.fetchClient = fetchClient
        self.extractor = extractor
        self.webSearchService = webSearchService ?? WebSearchService(fetchClient: fetchClient)
        self.maxRequests = maxRequests
    }

    // MARK: - BackgroundWorker

    func execute(
        taskID: UUID,
        input: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy
    ) async throws -> WorkerResult {
        // Reset per-task state on SafeURLSession to scope request counting per-task
        if let safeSession = self.fetchClient as? SafeURLSession {
            safeSession.resetForNewTask()
        }

        let startedAt = Date()
        var pages: [PageResult] = []
        var failedPages: [FailedPage] = []

        let resolvedInput = try await self.resolveInputURLs(input: input, policy: policy)
        failedPages.append(contentsOf: resolvedInput.initialFailures)

        guard !resolvedInput.urls.isEmpty else {
            throw WorkerError.allPagesFailed(failedPages)
        }

        for urlString in resolvedInput.urls {
            try Task.checkCancellation()

            guard let url = URL(string: urlString) else {
                failedPages.append(
                    FailedPage(
                        url: urlString,
                        finalURL: nil,
                        code: .invalidURL,
                        message: "Invalid URL.",
                        statusCode: nil,
                        failedAt: Date()
                    )
                )
                continue
            }

            do {
                let response = try await self.fetchClient.fetch(url: url, policy: policy)
                let page = try self.makePageResult(
                    sourceURL: url,
                    response: response
                )
                pages.append(page)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WorkerPageError {
                failedPages.append(
                    FailedPage(
                        url: url.absoluteString,
                        finalURL: error.finalURL?.absoluteString,
                        code: error.code,
                        message: error.message,
                        statusCode: error.statusCode,
                        failedAt: Date()
                    )
                )
            } catch {
                failedPages.append(
                    FailedPage(
                        url: url.absoluteString,
                        finalURL: nil,
                        code: .fetchFailed,
                        message: error.localizedDescription,
                        statusCode: nil,
                        failedAt: Date()
                    )
                )
            }
        }

        guard !pages.isEmpty else {
            throw WorkerError.allPagesFailed(failedPages)
        }

        return WorkerResult(
            pages: pages,
            metadata: WorkerMetadata(
                taskID: taskID,
                taskKind: policy.taskKind,
                startedAt: startedAt,
                completedAt: Date(),
                requestedURLCount: resolvedInput.urls.count,
                succeededURLCount: pages.count,
                failedURLCount: failedPages.count,
                processedSequentially: true
            ),
            failedURLs: failedPages,
            provenance: resolvedInput.provenance
        )
    }

    // MARK: - Helpers

    private func resolveInputURLs(
        input: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy
    ) async throws -> ResolvedWorkerInput {
        guard let query = input.query else {
            return ResolvedWorkerInput(urls: input.urls)
        }

        let searchResultLimit = self.searchResultLimit(explicitURLCount: input.urls.count)
        guard searchResultLimit > 0 else {
            self.logger.info(
                "Skipping additional web search because explicit URL count already fills the in-process request budget"
            )
            return ResolvedWorkerInput(urls: input.urls)
        }

        do {
            let searchResult = try await self.webSearchService.search(
                query: query,
                maxResults: searchResultLimit,
                policy: policy
            )
            let mergedURLs = self.mergeURLs(
                explicitURLs: input.urls,
                discoveredURLs: searchResult.urls
            )
            let provenance = self.makeProvenance(query: query, searchResult: searchResult)

            if mergedURLs.isEmpty {
                return ResolvedWorkerInput(
                    urls: [],
                    initialFailures: [self.searchFailure(for: query, message: "Search returned no URLs.")],
                    provenance: provenance
                )
            }

            return ResolvedWorkerInput(
                urls: mergedURLs,
                provenance: provenance
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !input.urls.isEmpty else {
                throw WorkerError.allPagesFailed([
                    self.searchFailure(for: query, message: "Search failed: \(error.localizedDescription)")
                ])
            }

            self.logger.warning(
                "Web search failed for query hash \(query, privacy: .private(mask: .hash)); continuing with explicit URLs only"
            )

            return ResolvedWorkerInput(urls: input.urls)
        }
    }

    private func mergeURLs(
        explicitURLs: [String],
        discoveredURLs: [URL]
    ) -> [String] {
        var merged: [String] = []
        var seen: Set<String> = []

        for urlString in explicitURLs {
            let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }

            let key = self.deduplicationKey(for: normalized)
            guard !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            merged.append(normalized)
        }

        for url in discoveredURLs {
            let normalized = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = self.deduplicationKey(for: normalized)
            guard !normalized.isEmpty,
                  !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            merged.append(normalized)
        }

        return merged
    }

    private func searchResultLimit(explicitURLCount: Int) -> Int {
        // Reserve 1 request for the DDG search itself; remaining budget is for page fetches.
        // Uses the actual maxRequests from the safety policy, not the default.
        let remainingRequestBudget = max(0, self.maxRequests - 1 - explicitURLCount)
        return min(8, remainingRequestBudget)
    }

    private func makeProvenance(
        query: String,
        searchResult: WebSearchResult
    ) -> WorkerProvenance {
        return WorkerProvenance(
            query: query,
            searchQueries: searchResult.searchQuery.isEmpty ? [] : [searchResult.searchQuery],
            discoveryRationale: nil,
            domainsUsed: self.domains(from: searchResult.urls)
        )
    }

    private func deduplicationKey(for urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? urlString
    }

    private func domains(from urls: [URL]) -> [String] {
        var domains: [String] = []
        var seen: Set<String> = []

        for url in urls {
            guard let host = url.host?.lowercased(), !host.isEmpty else {
                continue
            }

            let normalizedHost: String
            if host.hasPrefix("www.") {
                normalizedHost = String(host.dropFirst(4))
            } else {
                normalizedHost = host
            }

            guard !seen.contains(normalizedHost) else {
                continue
            }

            seen.insert(normalizedHost)
            domains.append(normalizedHost)
        }

        return domains
    }

    private func searchFailure(for query: String, message: String) -> FailedPage {
        return FailedPage(
            url: "search://\(query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query)",
            finalURL: nil,
            code: .fetchFailed,
            message: message,
            statusCode: nil,
            failedAt: Date()
        )
    }

    private func makePageResult(
        sourceURL: URL,
        response: FetchedPageResponse
    ) throws -> PageResult {
        let contentType = self.normalizedContentType(response.contentType)
        let decodedBody = try self.decodeBody(response.body, encodingName: response.textEncodingName)

        switch contentType {
        case let type where type.contains("html"):
            let extracted = self.extractor.extract(from: decodedBody)
            return PageResult(
                url: sourceURL.absoluteString,
                finalURL: response.finalURL.absoluteString,
                title: extracted.title,
                text: extracted.text,
                contentType: contentType,
                wordCount: Self.wordCount(for: extracted.text),
                fetchedAt: response.fetchedAt,
                rawHTML: decodedBody
            )

        case "text/plain":
            let text = decodedBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return PageResult(
                url: sourceURL.absoluteString,
                finalURL: response.finalURL.absoluteString,
                title: nil,
                text: text,
                contentType: contentType,
                wordCount: Self.wordCount(for: text),
                fetchedAt: response.fetchedAt,
                rawHTML: nil
            )

        default:
            throw WorkerPageError(
                code: .unsupportedContentType,
                message: "Unsupported content type: \(contentType).",
                statusCode: response.statusCode,
                finalURL: response.finalURL
            )
        }
    }

    private func normalizedContentType(_ contentType: String?) -> String {
        let rawContentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawContentType.isEmpty else {
            return "text/html"
        }

        return rawContentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? rawContentType.lowercased()
    }

    private func decodeBody(_ body: Data, encodingName: String?) throws -> String {
        let encodings = Self.encodings(from: encodingName) + [.utf8, .isoLatin1]
        for encoding in encodings {
            if let decoded = String(data: body, encoding: encoding) {
                return decoded
            }
        }

        throw WorkerPageError(
            code: .extractionFailed,
            message: "Response body could not be decoded as text.",
            statusCode: nil,
            finalURL: nil
        )
    }

    private static func encodings(from encodingName: String?) -> [String.Encoding] {
        guard let encodingName else {
            return []
        }

        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return []
        }

        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return [String.Encoding(rawValue: nsEncoding)]
    }

    private static func wordCount(for text: String) -> Int {
        return text.split(whereSeparator: \.isWhitespace).count
    }
}

private struct ResolvedWorkerInput: Sendable {
    let urls: [String]
    let initialFailures: [FailedPage]
    let provenance: WorkerProvenance?

    init(
        urls: [String],
        initialFailures: [FailedPage] = [],
        provenance: WorkerProvenance? = nil
    ) {
        self.urls = urls
        self.initialFailures = initialFailures
        self.provenance = provenance
    }
}

private struct WorkerPageError: Error, Equatable, Sendable {
    let code: WorkerFailureCode
    let message: String
    let statusCode: Int?
    let finalURL: URL?
}

struct URLSessionFetchClient: WorkerFetchClient {

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    func fetch(request: URLRequest, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        var request = request
        guard let requestURL = request.url else {
            throw WorkerPageError(
                code: .invalidURL,
                message: "Invalid request URL.",
                statusCode: nil,
                finalURL: nil
            )
        }

        request.timeoutInterval = TimeInterval(policy.timeoutSeconds)
        request.httpShouldHandleCookies = false

        let fetchedAt = Date()
        let (body, response) = try await self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkerPageError(
                code: .invalidResponse,
                message: "Expected an HTTP response.",
                statusCode: nil,
                finalURL: response.url
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkerPageError(
                code: .fetchFailed,
                message: "Request failed with status \(httpResponse.statusCode).",
                statusCode: httpResponse.statusCode,
                finalURL: httpResponse.url ?? requestURL
            )
        }

        return FetchedPageResponse(
            finalURL: httpResponse.url ?? requestURL,
            statusCode: httpResponse.statusCode,
            contentType: httpResponse.mimeType,
            textEncodingName: httpResponse.textEncodingName,
            body: body,
            fetchedAt: fetchedAt
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
