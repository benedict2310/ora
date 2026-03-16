//
//  SafeURLSession.swift
//  Ora
//
//  Policy-enforcing fetch client that validates URLs, response sizes,
//  content types, and redirect targets before returning data.
//

import Foundation
import os

final class SafeURLSession: WorkerFetchClient, @unchecked Sendable {

    private let safetyPolicy: NetworkSafetyPolicy
    private let validator: URLSafetyValidator
    private let logger = Logger.ora(category: "network-safety")

    private let lock = NSLock()
    private var requestCount = 0

    init(
        safetyPolicy: NetworkSafetyPolicy = NetworkSafetyPolicy(),
        resolver: any URLHostResolver = SystemURLResolver()
    ) {
        self.safetyPolicy = safetyPolicy
        self.validator = URLSafetyValidator(resolver: resolver, policy: safetyPolicy)
    }

    // MARK: - WorkerFetchClient

    func fetch(url: URL, policy: BackgroundTaskPolicy) async throws -> FetchedPageResponse {
        try self.incrementRequestCount()

        // Validate the URL before fetching
        try await self.validator.validate(url: url)

        let session = self.makeEphemeralSession(policy: policy)
        defer { session.invalidateAndCancel() }

        let delegate = RedirectValidator(validator: self.validator, maxRedirects: self.safetyPolicy.maxRedirects)

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(
            min(self.safetyPolicy.requestTimeoutSeconds, policy.timeoutSeconds)
        )
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("", forHTTPHeaderField: "Referer")

        let fetchedAt = Date()
        let (asyncBytes, response) = try await session.bytes(for: request, delegate: delegate)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkSafetyError.blockedHost("invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "SafeURLSession",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Request failed with status \(httpResponse.statusCode)."]
            )
        }

        // Validate content type from headers before reading body
        let contentType = httpResponse.mimeType
        try self.validator.validateContentType(contentType)

        // Read body with size enforcement
        let body = try await self.readBody(asyncBytes: asyncBytes)

        return FetchedPageResponse(
            finalURL: httpResponse.url ?? url,
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            textEncodingName: httpResponse.textEncodingName,
            body: body,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Task Boundary

    /// Reset per-task state. Must be called at the start of each background task
    /// to ensure request counting is scoped per-task, not per-instance lifetime.
    func resetForNewTask() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.requestCount = 0
    }

    // MARK: - Request Counting

    private func incrementRequestCount() throws {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.requestCount += 1
        if self.requestCount > self.safetyPolicy.maxRequests {
            throw NetworkSafetyError.tooManyRequests(limit: self.safetyPolicy.maxRequests)
        }
    }

    // MARK: - Body Reading

    private func readBody(asyncBytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        let limit = self.safetyPolicy.maxResponseBytes

        for try await byte in asyncBytes {
            data.append(byte)
            if data.count > limit {
                throw NetworkSafetyError.responseTooLarge(
                    bytes: Int64(data.count),
                    limit: limit
                )
            }
        }

        return data
    }

    // MARK: - Session Factory

    private func makeEphemeralSession(policy: BackgroundTaskPolicy) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = TimeInterval(
            min(self.safetyPolicy.requestTimeoutSeconds, policy.timeoutSeconds)
        )
        return URLSession(configuration: configuration)
    }
}

// MARK: - Redirect Validator

private final class RedirectValidator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let validator: URLSafetyValidator
    private let maxRedirects: Int
    private let lock = NSLock()
    private var redirectCount = 0

    init(validator: URLSafetyValidator, maxRedirects: Int) {
        self.validator = validator
        self.maxRedirects = maxRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        self.lock.lock()
        self.redirectCount += 1
        let currentCount = self.redirectCount
        self.lock.unlock()

        if currentCount > self.maxRedirects {
            completionHandler(nil)
            return
        }

        guard let redirectURL = request.url else {
            completionHandler(nil)
            return
        }

        // Validate redirect target synchronously for scheme and host presence,
        // then asynchronously for IP resolution
        Task {
            do {
                try await self.validator.validate(url: redirectURL)
                completionHandler(request)
            } catch {
                completionHandler(nil)
            }
        }
    }
}
