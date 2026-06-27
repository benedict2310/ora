//
//  WebSearchService.swift
//  Ora
//
//  In-process DuckDuckGo HTML Lite search for query-based research.
//

import Foundation
import CoreFoundation
import os

protocol WebSearchServicing: Sendable {
    func search(
        query: String,
        maxResults: Int,
        policy: BackgroundTaskPolicy
    ) async throws -> WebSearchResult
}

struct WebSearchResult: Sendable, Equatable {
    let urls: [URL]
    let searchQuery: String
}

struct WebSearchService: WebSearchServicing {

    // MARK: - Constants

    private static let searchEndpoint = URL(string: "https://html.duckduckgo.com/html/")!
    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let internalHosts: Set<String> = [
        "duckduckgo.com",
        "www.duckduckgo.com",
        "html.duckduckgo.com",
        "links.duckduckgo.com",
        "duck.co",
        "www.duck.co"
    ]

    // MARK: - Properties

    private let fetchClient: any WorkerFetchClient
    private let logger = Logger.ora(category: "orchestration")

    // MARK: - Init

    init(fetchClient: any WorkerFetchClient = SafeURLSession()) {
        self.fetchClient = fetchClient
    }

    // MARK: - Public

    func search(
        query: String,
        maxResults: Int = 8,
        policy: BackgroundTaskPolicy
    ) async throws -> WebSearchResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cappedMaxResults = max(0, maxResults)

        guard !trimmedQuery.isEmpty, cappedMaxResults > 0 else {
            return WebSearchResult(urls: [], searchQuery: trimmedQuery)
        }

        let request = self.makeSearchRequest(query: trimmedQuery, policy: policy)
        let response = try await self.fetchClient.fetch(request: request, policy: policy)
        let html = try self.decodeBody(response.body, encodingName: response.textEncodingName)
        let urls = self.extractResultURLs(from: html, maxResults: cappedMaxResults)

        self.logger.info(
            "Web search discovered \(urls.count) URL(s) for query hash \(trimmedQuery, privacy: .private(mask: .hash))"
        )

        return WebSearchResult(urls: urls, searchQuery: trimmedQuery)
    }

    func extractResultURLs(from html: String, maxResults: Int = 8) -> [URL] {
        guard !html.isEmpty, maxResults > 0 else {
            return []
        }

        var collectedURLs: [URL] = []
        var seenDomains: Set<String> = []
        var seenURLs: Set<String> = []

        for tag in self.anchorTags(in: html) {
            guard let classValue = self.attribute(named: "class", in: tag),
                  self.isSearchResultClass(classValue),
                  let href = self.attribute(named: "href", in: tag),
                  let url = self.resolvedResultURL(from: href) else {
                continue
            }

            let domain = self.normalizedDomain(for: url)
            let urlKey = url.absoluteString.lowercased()

            guard !domain.isEmpty,
                  !seenDomains.contains(domain),
                  !seenURLs.contains(urlKey) else {
                continue
            }

            seenDomains.insert(domain)
            seenURLs.insert(urlKey)
            collectedURLs.append(url)

            if collectedURLs.count >= maxResults {
                break
            }
        }

        return collectedURLs
    }

    // MARK: - Request Construction

    private func makeSearchRequest(query: String, policy: BackgroundTaskPolicy) -> URLRequest {
        var request = URLRequest(url: Self.searchEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(policy.timeoutSeconds)
        request.httpShouldHandleCookies = false
        request.httpBody = Data("q=\(Self.formURLEncode(query))&b=".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://html.duckduckgo.com/html/", forHTTPHeaderField: "Referer")
        return request
    }

    private static func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=%?/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - HTML Parsing

    private func anchorTags(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: html) else {
                return nil
            }
            return String(html[matchRange])
        }
    }

    private func attribute(named name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b\(escapedName)\\s*=\\s*([\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              match.numberOfRanges > 2,
              let valueRange = Range(match.range(at: 2), in: tag) else {
            return nil
        }

        return self.decodeEntities(String(tag[valueRange]))
    }

    private func isSearchResultClass(_ classValue: String) -> Bool {
        let classes = classValue
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        return classes.contains("result__a") || classes.contains("result__url")
    }

    private func resolvedResultURL(from rawHref: String) -> URL? {
        let trimmedHref = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHref.isEmpty,
              let candidateURL = self.absoluteURL(from: trimmedHref) else {
            return nil
        }

        if self.isTrackingRedirect(candidateURL) {
            return self.redirectTarget(from: candidateURL)
        }

        guard self.isAllowedDiscoveredURL(candidateURL) else {
            return nil
        }

        return candidateURL
    }

    private func absoluteURL(from href: String) -> URL? {
        if href.hasPrefix("//") {
            return URL(string: "https:\(href)")
        }

        if href.hasPrefix("/") {
            return URL(string: href, relativeTo: Self.searchEndpoint)?.absoluteURL
        }

        return URL(string: href)
    }

    private func isTrackingRedirect(_ url: URL) -> Bool {
        guard self.isInternalDuckDuckGoHost(url.host) else {
            return false
        }

        let path = url.path.lowercased()
        return path == "/l" || path.hasPrefix("/l/")
    }

    private func redirectTarget(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let target = components.queryItems?.first(where: { $0.name.lowercased() == "uddg" })?.value,
              let resolvedURL = URL(string: target) ?? target.removingPercentEncoding.flatMap(URL.init(string:)) else {
            return nil
        }

        guard self.isAllowedDiscoveredURL(resolvedURL) else {
            return nil
        }

        return resolvedURL
    }

    private func isAllowedDiscoveredURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              !self.isInternalDuckDuckGoHost(host) else {
            return false
        }

        return true
    }

    private func isInternalDuckDuckGoHost(_ host: String?) -> Bool {
        guard let host else {
            return false
        }

        let normalizedHost = host.lowercased()
        if Self.internalHosts.contains(normalizedHost) {
            return true
        }

        return normalizedHost.hasSuffix(".duckduckgo.com") || normalizedHost.hasSuffix(".duck.co")
    }

    private func normalizedDomain(for url: URL) -> String {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return ""
        }

        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }

        return host
    }

    // MARK: - Decoding

    private func decodeBody(_ body: Data, encodingName: String?) throws -> String {
        let encodings = Self.encodings(from: encodingName) + [.utf8, .isoLatin1]
        for encoding in encodings {
            if let decoded = String(data: body, encoding: encoding) {
                return decoded
            }
        }

        throw WebSearchServiceError.responseDecodingFailed
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

    private func decodeEntities(_ text: String) -> String {
        var decoded = text
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " ")
        ]

        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }

        decoded = self.replacingMatches(in: decoded, pattern: #"&#x([0-9a-fA-F]+);"#) { match in
            guard let scalarValue = UInt32(match, radix: 16),
                  let scalar = UnicodeScalar(scalarValue) else {
                return ""
            }
            return String(Character(scalar))
        }

        decoded = self.replacingMatches(in: decoded, pattern: #"&#([0-9]+);"#) { match in
            guard let scalarValue = UInt32(match),
                  let scalar = UnicodeScalar(scalarValue) else {
                return ""
            }
            return String(Character(scalar))
        }

        return decoded
    }

    private func replacingMatches(
        in text: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else {
            return text
        }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else {
                continue
            }

            let replacement = transform(String(result[captureRange]))
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }
}

private enum WebSearchServiceError: LocalizedError, Sendable {
    case responseDecodingFailed

    var errorDescription: String? {
        switch self {
        case .responseDecodingFailed:
            return "Search response body could not be decoded as text."
        }
    }
}
