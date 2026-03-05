//
//  CloudProviderError.swift
//  Ora
//
//  Errors for cloud LLM providers
//

import Foundation

/// Errors from cloud LLM providers
public enum CloudProviderError: LocalizedError {
    case authenticationFailed(String)
    case billingError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int, body: String)
    case requestFailed(statusCode: Int, body: String)
    case unsupportedInput(String)
    case connectionFailed(Error)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason): return "Authentication failed: \(reason)"
        case .billingError(let reason): return "Billing error: \(reason)"
        case .rateLimited(let retryAfter): return "Rate limited (retry after \(retryAfter ?? 0)s)"
        case .serverError(let statusCode, let body): return "Server error \(statusCode): \(body)"
        case .requestFailed(let statusCode, let body): return "Request failed \(statusCode): \(body)"
        case .unsupportedInput(let reason): return reason
        case .connectionFailed(let error): return "Connection failed: \(error.localizedDescription)"
        case .invalidResponse(let reason): return "Invalid response: \(reason)"
        }
    }

    /// Whether this error should trigger a fallback to local
    public var shouldFallback: Bool {
        switch self {
        case .authenticationFailed, .billingError: return true
        case .rateLimited: return false  // Retry instead
        case .serverError, .connectionFailed: return true
        case .requestFailed, .unsupportedInput, .invalidResponse: return false
        }
    }
}

/// Provider-level errors
public enum ProviderError: LocalizedError {
    case providerNotRegistered(LLMProviderType)
    case noCredential(LLMProviderType)
    case invalidModel(LLMProviderType, String)
    case switchFailed(LLMProviderType, Error)

    public var errorDescription: String? {
        switch self {
        case .providerNotRegistered(let type): return "Provider \(type) not registered"
        case .noCredential(let type): return "No credential found for \(type)"
        case .invalidModel(let type, let model): return "Invalid model '\(model)' for \(type)"
        case .switchFailed(let type, let error): return "Failed to switch to \(type): \(error.localizedDescription)"
        }
    }
}
