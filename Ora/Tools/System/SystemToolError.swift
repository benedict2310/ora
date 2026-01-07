//
//  SystemToolError.swift
//  Ora
//
//  Errors for system tools
//

import Foundation

enum SystemToolError: LocalizedError {
    case notFound(String)
    case failed(String)
    case invalidArgument(String)
    
    var errorDescription: String? {
        switch self {
        case .notFound(let item):
            return "\(item) not found"
        case .failed(let reason):
            return "Operation failed: \(reason)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        }
    }
}
