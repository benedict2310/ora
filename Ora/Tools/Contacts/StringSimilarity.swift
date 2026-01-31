//
//  StringSimilarity.swift
//  Ora
//
//  Jaro-Winkler string similarity for fuzzy name matching.
//

import Foundation

enum StringSimilarity {

    /// Jaro similarity between two strings (0.0 – 1.0).
    static func jaro(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1.lowercased())
        let b = Array(s2.lowercased())

        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        if a == b { return 1.0 }

        let matchDistance = max(a.count, b.count) / 2 - 1
        guard matchDistance >= 0 else {
            // Both strings are length 1 and differ
            return 0.0
        }

        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)

        var matches = 0
        var transpositions = 0

        // Find matching characters
        for i in a.indices {
            let lo = max(0, i - matchDistance)
            let hi = min(b.count - 1, i + matchDistance)
            guard lo <= hi else { continue }
            for j in lo...hi {
                guard !bMatched[j], a[i] == b[j] else { continue }
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
        }

        if matches == 0 { return 0.0 }

        // Count transpositions
        var k = 0
        for i in a.indices where aMatched[i] {
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        let t = Double(transpositions) / 2.0
        return (m / Double(a.count) + m / Double(b.count) + (m - t) / m) / 3.0
    }

    /// Jaro-Winkler similarity (adds prefix bonus to Jaro).
    ///
    /// - Parameters:
    ///   - s1: First string.
    ///   - s2: Second string.
    ///   - prefixScale: Winkler prefix scaling factor (default 0.1, max 0.25).
    /// - Returns: Similarity score in 0.0 – 1.0.
    static func jaroWinkler(_ s1: String, _ s2: String, prefixScale: Double = 0.1) -> Double {
        let j = jaro(s1, s2)

        // Common prefix length (up to 4 characters)
        let a = Array(s1.lowercased())
        let b = Array(s2.lowercased())
        let prefixLimit = min(4, min(a.count, b.count))
        var commonPrefix = 0
        for i in 0..<prefixLimit {
            guard a[i] == b[i] else { break }
            commonPrefix += 1
        }

        let p = min(prefixScale, 0.25)
        return j + Double(commonPrefix) * p * (1.0 - j)
    }

    /// Best Jaro-Winkler score between a query and multiple candidate strings.
    /// Returns the maximum score found across all candidates.
    static func bestScore(query: String, candidates: [String]) -> Double {
        candidates.map { jaroWinkler(query, $0) }.max() ?? 0.0
    }
}
