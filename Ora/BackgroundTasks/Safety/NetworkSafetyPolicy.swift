//
//  NetworkSafetyPolicy.swift
//  Ora
//
//  Codable policy values controlling network safety enforcement.
//

import Foundation

struct NetworkSafetyPolicy: Codable, Sendable, Equatable {

    // MARK: - Defaults

    static let defaultMaxResponseBytes = 5_242_880 // 5 MB
    static let defaultMaxRequests = 10
    static let defaultAllowedContentTypes = [
        "text/html",
        "text/plain",
        "application/json",
        "application/xml",
        "text/xml"
    ]
    static let defaultMaxRedirects = 5

    // MARK: - Properties

    let maxResponseBytes: Int
    let maxRequests: Int
    let allowedDomains: [String]?
    let allowedContentTypes: [String]
    let requestTimeoutSeconds: Int
    let maxRedirects: Int

    init(
        maxResponseBytes: Int = NetworkSafetyPolicy.defaultMaxResponseBytes,
        maxRequests: Int = NetworkSafetyPolicy.defaultMaxRequests,
        allowedDomains: [String]? = nil,
        allowedContentTypes: [String] = NetworkSafetyPolicy.defaultAllowedContentTypes,
        requestTimeoutSeconds: Int = BackgroundTaskPolicy.defaultTimeoutSeconds,
        maxRedirects: Int = NetworkSafetyPolicy.defaultMaxRedirects
    ) {
        self.maxResponseBytes = maxResponseBytes
        self.maxRequests = maxRequests
        self.allowedDomains = allowedDomains
        self.allowedContentTypes = allowedContentTypes
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxRedirects = maxRedirects
    }
}
