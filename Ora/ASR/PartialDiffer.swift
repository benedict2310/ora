//
//  PartialDiffer.swift
//  Ora
//
//  Text diffing for stable, non-flickering partial transcription updates.
//

import Foundation

// MARK: - DiffResult

/// Result of diffing operation
public struct DiffResult: Sendable, Equatable {
    /// Only the newly added text since last confirmed state
    public let newText: String

    /// Whether the current text appears stable (unchanged for multiple hops)
    public let isStable: Bool

    /// Complete accumulated text (confirmed + pending)
    public let fullText: String

    /// Text that has been confirmed stable
    public let confirmedText: String

    /// Text that is still pending (may change)
    public let pendingText: String
}

// MARK: - PartialDiffer

/// Tracks transcription changes and emits stable deltas.
///
/// The differ maintains three states:
/// 1. **Confirmed**: Text that has been stable for N consecutive hops
/// 2. **Pending**: Text that is new but not yet stable
/// 3. **Delta**: The incremental change to emit
///
/// ## Example Flow
///
/// ```
/// Hop 1: Engine returns "Hello"
///   - confirmed: ""
///   - pending: "Hello"
///   - delta: "Hello"
///
/// Hop 2: Engine returns "Hello world"
///   - confirmed: ""
///   - pending: "Hello world"
///   - delta: "world"  (only the new part)
///
/// Hop 3: Engine returns "Hello world"  (stable!)
///   - confirmed: "Hello world"
///   - pending: ""
///   - delta: ""
///   - isStable: true
///
/// Hop 4: Engine returns "Hello world how"
///   - confirmed: "Hello world"
///   - pending: "how"
///   - delta: "how"
/// ```
public struct PartialDiffer: Sendable {

    // MARK: - Private State

    private var confirmed: String = ""
    private var pending: String = ""
    private var lastText: String = ""
    private var stabilityCount: Int = 0
    private let stabilityThreshold: Int

    // MARK: - Public Properties

    /// Currently confirmed (stable) text
    public var confirmedText: String { confirmed }

    // MARK: - Initialization

    /// Initialize with stability threshold
    /// - Parameter stabilityThreshold: Number of identical results before confirming
    public init(stabilityThreshold: Int = 2) {
        self.stabilityThreshold = stabilityThreshold
    }

    // MARK: - Public Methods

    /// Process new transcription text and compute diff
    /// - Parameter newText: Full transcription from engine
    /// - Returns: Diff result with stable changes
    public mutating func process(_ newText: String) -> DiffResult {
        let trimmedNew = newText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Track stability
        if trimmedNew == lastText {
            stabilityCount += 1
        } else {
            stabilityCount = 0
            lastText = trimmedNew
        }

        let isStable = stabilityCount >= stabilityThreshold

        // If stable, promote pending to confirmed
        if isStable && !pending.isEmpty {
            confirmed = confirmed.isEmpty ? pending : confirmed + " " + pending
            pending = ""
        }

        // Calculate what's new beyond confirmed text
        let newPortion = extractNewPortion(from: trimmedNew)
        let deltaText = calculateDelta(oldPending: pending, newPortion: newPortion)

        pending = newPortion

        let fullText = confirmed.isEmpty ? pending :
            (pending.isEmpty ? confirmed : confirmed + " " + pending)

        return DiffResult(
            newText: deltaText,
            isStable: isStable,
            fullText: fullText,
            confirmedText: confirmed,
            pendingText: pending
        )
    }

    /// Reset all state
    public mutating func reset() {
        confirmed = ""
        pending = ""
        lastText = ""
        stabilityCount = 0
    }

    // MARK: - Private Methods

    private func extractNewPortion(from text: String) -> String {
        guard !confirmed.isEmpty else { return text }

        // Find where confirmed text ends in new text
        if text.lowercased().hasPrefix(confirmed.lowercased()) {
            let startIndex = text.index(text.startIndex, offsetBy: confirmed.count)
            return String(text[startIndex...]).trimmingCharacters(in: .whitespaces)
        }

        // Fuzzy match: find longest common prefix
        let commonPrefix = longestCommonPrefix(confirmed.lowercased(), text.lowercased())
        if commonPrefix.count > confirmed.count / 2 {
            let startIndex = text.index(text.startIndex, offsetBy: commonPrefix.count)
            return String(text[startIndex...]).trimmingCharacters(in: .whitespaces)
        }

        // No match found - this might be a correction
        return text
    }

    private func calculateDelta(oldPending: String, newPortion: String) -> String {
        guard !oldPending.isEmpty else { return newPortion }

        // Find what's new in the pending portion
        if newPortion.lowercased().hasPrefix(oldPending.lowercased()) {
            let startIndex = newPortion.index(
                newPortion.startIndex,
                offsetBy: oldPending.count
            )
            return String(newPortion[startIndex...]).trimmingCharacters(in: .whitespaces)
        }

        // Text changed entirely - return full new portion
        return newPortion
    }

    private func longestCommonPrefix(_ a: String, _ b: String) -> String {
        var result = ""
        let aChars = Array(a)
        let bChars = Array(b)

        for i in 0..<min(aChars.count, bChars.count) {
            if aChars[i] == bChars[i] {
                result.append(aChars[i])
            } else {
                break
            }
        }

        return result
    }
}
