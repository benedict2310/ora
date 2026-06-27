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
    let query: String?

    init(urls: [String] = [], label: String? = nil, query: String? = nil) {
        self.urls = urls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmedLabel?.isEmpty == true ? nil : trimmedLabel
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmedQuery?.isEmpty == true ? nil : trimmedQuery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.urls = try container.decode([String].self, forKey: .urls)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.query = try container.decodeIfPresent(String.self, forKey: .query)
    }

    /// Whether this input has at least one actionable item (query or URLs).
    var hasContent: Bool {
        return self.query != nil || !self.urls.isEmpty
    }
}
