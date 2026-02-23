//
//  ContentSanitizer.swift
//  Ora
//
//  Sanitizes untrusted text content before LLM injection.
//

import Foundation

enum ContentSanitizer {

    static func sanitize(_ input: String) -> String {
        let filteredScalars = input.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return scalar == "\n" || scalar == "\t"
            }
            return true
        }

        let normalizedNewlines = String(String.UnicodeScalarView(filteredScalars))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let collapsedSpaces = normalizedNewlines.replacingOccurrences(
            of: "[\\t ]+",
            with: " ",
            options: String.CompareOptions.regularExpression
        )

        let collapsedBlankLines = collapsedSpaces.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: String.CompareOptions.regularExpression
        )

        return collapsedBlankLines.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
