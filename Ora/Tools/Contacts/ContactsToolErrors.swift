//
//  ContactsToolErrors.swift
//  Ora
//
//  Error types for contacts tools
//

import Foundation

enum ContactsToolError: LocalizedError {
    case permissionDenied
    case invalidArgument(String)
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Contacts access denied. Please grant permission in System Settings."
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        }
    }
}
