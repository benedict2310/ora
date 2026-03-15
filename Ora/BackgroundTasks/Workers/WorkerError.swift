//
//  WorkerError.swift
//  Ora
//
//  Typed worker failures surfaced to the queue lifecycle.
//

import Foundation

enum WorkerError: LocalizedError, Equatable, Sendable {
    case allPagesFailed([FailedPage])

    var errorDescription: String? {
        switch self {
        case .allPagesFailed(let failures):
            guard !failures.isEmpty else {
                return "Background task failed for every requested URL."
            }

            let preview = failures
                .prefix(2)
                .map { "\($0.url): \($0.message)" }
                .joined(separator: "; ")
            let suffix = failures.count > 2 ? " (+\(failures.count - 2) more)" : ""
            return "Background task failed for all \(failures.count) URLs. \(preview)\(suffix)"
        }
    }
}
