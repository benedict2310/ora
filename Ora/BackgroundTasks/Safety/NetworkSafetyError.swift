//
//  NetworkSafetyError.swift
//  Ora
//
//  Typed failures for network safety policy violations.
//

import Foundation

enum NetworkSafetyError: LocalizedError, Equatable, Sendable {
    case blockedScheme(String)
    case blockedHost(String)
    case blockedIP(String)
    case blockedDomain(String)
    case responseTooLarge(bytes: Int64, limit: Int)
    case unsupportedContentType(String)
    case tooManyRequests(limit: Int)
    case redirectToBlockedTarget(String)

    var errorDescription: String? {
        switch self {
        case .blockedScheme:
            return "The URL scheme is not allowed. Only HTTP and HTTPS are permitted."
        case .blockedHost:
            return "The request target host is not allowed."
        case .blockedIP:
            return "The request target address is not allowed."
        case .blockedDomain:
            return "The request target domain is not in the allowed list."
        case .responseTooLarge(_, let limit):
            return "The response exceeds the maximum allowed size of \(limit) bytes."
        case .unsupportedContentType:
            return "The response content type is not supported."
        case .tooManyRequests(let limit):
            return "The request limit of \(limit) has been reached."
        case .redirectToBlockedTarget:
            return "A redirect target was blocked by the safety policy."
        }
    }
}
