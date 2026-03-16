//
//  URLSessionWorker.swift
//  Ora
//
//  Phase-1 in-process worker for sequential URL fetch and text extraction.
//

import Foundation
import CoreFoundation

struct FetchedPageResponse: Sendable, Equatable {
    let finalURL: URL
    let statusCode: Int
    let contentType: String?
    let textEncodingName: String?
    let body: Data
    let fetchedAt: Date
}

protocol WorkerFetchClient: Sendable {
    func fetch(url: URL, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse
}

struct URLSessionWorker: BackgroundWorker {

    private let fetchClient: any WorkerFetchClient
    private let extractor: HTMLTextExtractor

    init(
        fetchClient: any WorkerFetchClient = SafeURLSession(),
        extractor: HTMLTextExtractor = HTMLTextExtractor()
    ) {
        self.fetchClient = fetchClient
        self.extractor = extractor
    }

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

        for urlString in input.urls {
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
                requestedURLCount: input.urls.count,
                succeededURLCount: pages.count,
                failedURLCount: failedPages.count,
                processedSequentially: true
            ),
            failedURLs: failedPages
        )
    }

    // MARK: - Helpers

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

    func fetch(url: URL, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        var request = URLRequest(url: url)
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
                finalURL: httpResponse.url ?? url
            )
        }

        return FetchedPageResponse(
            finalURL: httpResponse.url ?? url,
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
