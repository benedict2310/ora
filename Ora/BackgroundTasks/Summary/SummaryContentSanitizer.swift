//
//  SummaryContentSanitizer.swift
//  (renamed from ContentSanitizer to avoid conflict with Ora/Utilities/ContentSanitizer)
//  Ora
//
//  Strips unsafe content from fetched web pages before LLM inference.
//

import Foundation

struct SanitizablePageInput: Sendable {
    let url: String
    let title: String?
    let extractedText: String
}

struct SanitizedPage: Sendable, Equatable {
    let url: String
    let title: String?
    let sanitizedText: String
}

struct SummaryContentSanitizer: Sendable {

    // MARK: - Constants

    static let maxCharsPerPage = 4_000
    static let maxTotalChars = 8_000

    // MARK: - Public API

    func sanitize(pages: [SanitizablePageInput]) -> [SanitizedPage] {
        var results: [SanitizedPage] = []
        var totalChars = 0

        for page in pages {
            guard totalChars < Self.maxTotalChars else {
                break
            }

            var text = page.extractedText

            // Strip HTML tags
            text = Self.stripHTMLTags(text)

            // Strip control characters (0x00-0x1F except newline 0x0A and tab 0x09)
            text = Self.stripControlCharacters(text)

            // Strip Unicode invisible characters and RTL overrides
            text = Self.stripInvisibleUnicode(text)

            // Collapse whitespace
            text = Self.collapseWhitespace(text)

            // Cap per-page
            if text.count > Self.maxCharsPerPage {
                text = String(text.prefix(Self.maxCharsPerPage))
            }

            // Cap total
            let remaining = Self.maxTotalChars - totalChars
            if text.count > remaining {
                text = String(text.prefix(remaining))
            }

            guard !text.isEmpty else {
                continue
            }

            totalChars += text.count

            // Wrap in delimiters
            let wrapped = "[BEGIN FETCHED CONTENT FROM \(page.url)]\n\(text)\n[END FETCHED CONTENT]"

            results.append(SanitizedPage(
                url: page.url,
                title: page.title,
                sanitizedText: wrapped
            ))
        }

        return results
    }

    // MARK: - Private Helpers

    private static func stripHTMLTags(_ text: String) -> String {
        // Remove HTML tags using regex
        guard let regex = try? NSRegularExpression(pattern: "<[^>]*>", options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func stripControlCharacters(_ text: String) -> String {
        return String(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            // Keep newline (0x0A) and tab (0x09)
            if value == 0x0A || value == 0x09 {
                return true
            }
            // Strip other control characters (0x00-0x1F)
            if value <= 0x1F {
                return false
            }
            return true
        })
    }

    private static func stripInvisibleUnicode(_ text: String) -> String {
        return String(text.unicodeScalars.filter { scalar in
            let value = scalar.value

            // Zero-width characters
            if value == 0x200B || value == 0x200C || value == 0x200D || value == 0xFEFF {
                return false
            }

            // RTL/LTR overrides and marks
            if value >= 0x200E && value <= 0x200F {
                return false
            }
            if value >= 0x202A && value <= 0x202E {
                return false
            }
            if value >= 0x2066 && value <= 0x2069 {
                return false
            }

            // Other invisible formatting
            if value == 0x00AD { // soft hyphen
                return false
            }
            if value >= 0x2060 && value <= 0x2064 {
                return false
            }

            return true
        })
    }

    private static func collapseWhitespace(_ text: String) -> String {
        // Collapse runs of spaces/tabs within lines, and collapse multiple blank lines
        guard let spaceRegex = try? NSRegularExpression(pattern: "[\\t ]+", options: []),
              let blankLineRegex = try? NSRegularExpression(pattern: "\\n{3,}", options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = spaceRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")

        let resultRange = NSRange(result.startIndex..., in: result)
        result = blankLineRegex.stringByReplacingMatches(in: result, options: [], range: resultRange, withTemplate: "\n\n")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
