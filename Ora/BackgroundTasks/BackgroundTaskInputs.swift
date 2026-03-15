//
//  BackgroundTaskInputs.swift
//  Ora
//
//  Codable user inputs for background tasks.
//

import Foundation

struct BackgroundTaskInputs: Codable, Sendable, Equatable {
    let urls: [String]
    let label: String?

    init(urls: [String], label: String? = nil) {
        self.urls = urls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmedLabel?.isEmpty == true ? nil : trimmedLabel
    }
}
