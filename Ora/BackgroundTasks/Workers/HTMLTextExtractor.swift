//
//  HTMLTextExtractor.swift
//  Ora
//
//  Lightweight in-repo HTML-to-text extraction for research fetches.
//

import Foundation

struct HTMLExtractionResult: Sendable, Equatable {
    let title: String?
    let text: String
}

struct HTMLTextExtractor: Sendable {

    func extract(from html: String) -> HTMLExtractionResult {
        guard !html.isEmpty else {
            return HTMLExtractionResult(title: nil, text: "")
        }

        let normalizedHTML = html.replacingOccurrences(
            of: "\r\n?",
            with: "\n",
            options: .regularExpression
        )

        let title = self.cleanInlineText(
            self.firstMatch(
                in: normalizedHTML,
                pattern: #"<title\b[^>]*>(.*?)</title>"#
            )
        )

        var workingHTML = normalizedHTML
        workingHTML = self.replacingMatches(
            in: workingHTML,
            pattern: #"<!--.*?-->"#,
            with: ""
        )
        workingHTML = self.replacingMatches(
            in: workingHTML,
            pattern: #"<(script|style|noscript)\b[^>]*>.*?</\1>"#,
            with: ""
        )
        workingHTML = self.replacingMatches(
            in: workingHTML,
            pattern: #"<br\s*/?>"#,
            with: "\n"
        )
        workingHTML = self.replacingMatches(
            in: workingHTML,
            pattern: #"</?(address|article|aside|blockquote|div|dl|dt|dd|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|table|tbody|td|tfoot|th|thead|tr|ul)\b[^>]*>"#,
            with: "\n\n"
        )
        workingHTML = self.replacingMatches(
            in: workingHTML,
            pattern: #"<[^>]+>"#,
            with: " "
        )

        let text = self.cleanBlockText(workingHTML)
        return HTMLExtractionResult(title: title, text: text)
    }

    // MARK: - Helpers

    private func cleanInlineText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let cleaned = self.normalizeWhitespace(
            self.decodeEntities(text)
        )
        return cleaned.isEmpty ? nil : cleaned
    }

    private func cleanBlockText(_ text: String) -> String {
        let decoded = self.decodeEntities(text)
        var cleaned = decoded.replacingOccurrences(
            of: #"[ \t\f\v]+"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #" *\n *"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #" +([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = self.normalizeWhitespace(cleaned, preserveParagraphBreaks: true)
        return cleaned
    }

    private func normalizeWhitespace(
        _ text: String,
        preserveParagraphBreaks: Bool = false
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        if preserveParagraphBreaks {
            return trimmed
        }

        return trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }

    private func decodeEntities(_ text: String) -> String {
        var decoded = text
        let namedEntities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'")
        ]
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }

        decoded = self.replacingMatches(
            in: decoded,
            pattern: #"&#x([0-9a-fA-F]+);"#
        ) { match in
            guard let scalarValue = UInt32(match, radix: 16),
                  let scalar = UnicodeScalar(scalarValue) else {
                return ""
            }
            return String(Character(scalar))
        }

        decoded = self.replacingMatches(
            in: decoded,
            pattern: #"&#([0-9]+);"#
        ) { match in
            guard let scalarValue = UInt32(match),
                  let scalar = UnicodeScalar(scalarValue) else {
                return ""
            }
            return String(Character(scalar))
        }

        return decoded
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        guard match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func replacingMatches(
        in text: String,
        pattern: String,
        with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
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
