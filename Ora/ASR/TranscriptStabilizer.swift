//
//  TranscriptStabilizer.swift
//  Ora
//
//  Text stability detection for preventing jittery partial emissions.
//

import Foundation

/// Detects when transcript text has meaningfully changed vs minor variations.
///
/// This prevents jittery partial emissions that occur when:
/// - Only punctuation changes (e.g., "Hello" → "Hello.")
/// - Only capitalization changes (e.g., "hello world" → "Hello world")
/// - Minor word corrections that quickly revert
///
/// ## Usage
/// ```swift
/// var stabilizer = TranscriptStabilizer()
///
/// // Returns true only when text meaningfully changed
/// if stabilizer.shouldEmit("Hello world") {
///     emitPartial("Hello world")
/// }
/// ```
public struct TranscriptStabilizer: Sendable {

    // MARK: - Configuration

    /// Number of consecutive identical texts before considering stable
    public let stabilityThreshold: Int

    /// Minimum character difference to consider a meaningful change
    public let minCharacterDifference: Int

    // MARK: - State

    private var lastEmittedText: String = ""
    private var lastRawText: String = ""
    private var stabilityCount: Int = 0
    private var unchangedSince: Date?

    // MARK: - Public Properties

    /// The last text that was emitted
    public var lastEmitted: String { lastEmittedText }

    /// Whether the current text is considered stable (unchanged for multiple checks)
    public var isStable: Bool { stabilityCount >= stabilityThreshold }

    /// Time since text last changed (nil if never checked or just changed)
    public var timeSinceLastChange: TimeInterval? {
        guard let since = unchangedSince else { return nil }
        return Date().timeIntervalSince(since)
    }

    // MARK: - Initialization

    /// Initialize with configuration
    /// - Parameters:
    ///   - stabilityThreshold: Number of identical checks before stable (default: 2)
    ///   - minCharacterDifference: Minimum char diff for meaningful change (default: 1)
    public init(stabilityThreshold: Int = 2, minCharacterDifference: Int = 1) {
        self.stabilityThreshold = stabilityThreshold
        self.minCharacterDifference = minCharacterDifference
    }

    // MARK: - Public API

    /// Check if the new text should be emitted as a partial.
    ///
    /// Returns `true` if the text has meaningfully changed from the last emission.
    /// Updates internal state regardless of return value.
    ///
    /// - Parameter newText: The new transcript text
    /// - Returns: `true` if the text should be emitted, `false` if it's too similar
    public mutating func shouldEmit(_ newText: String) -> Bool {
        let normalized = normalize(newText)
        let lastNormalized = normalize(lastRawText)

        // Track stability
        if normalized == lastNormalized {
            stabilityCount += 1
            // Don't reset unchangedSince - text hasn't changed
        } else {
            stabilityCount = 0
            unchangedSince = Date()
        }

        lastRawText = newText

        // Check if meaningfully different from last emitted
        let lastEmittedNormalized = normalize(lastEmittedText)
        if isMeaningfullyDifferent(normalized, from: lastEmittedNormalized) {
            lastEmittedText = newText
            return true
        }

        return false
    }

    /// Check if the text has been unchanged for the given duration.
    ///
    /// - Parameter duration: Time in seconds
    /// - Returns: `true` if text unchanged for at least `duration` seconds
    public func hasBeenStableFor(_ duration: TimeInterval) -> Bool {
        guard let timeSince = timeSinceLastChange else { return false }
        return timeSince >= duration
    }

    /// Reset all state
    public mutating func reset() {
        lastEmittedText = ""
        lastRawText = ""
        stabilityCount = 0
        unchangedSince = nil
    }

    // MARK: - Private Methods

    /// Normalize text for comparison (strips punctuation, lowercases)
    private func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing punctuation that commonly oscillates
        let punctuationToStrip = CharacterSet(charactersIn: ".,!?;:'\"-")
        let stripped = trimmed.trimmingCharacters(in: punctuationToStrip)

        // Lowercase for case-insensitive comparison
        return stripped.lowercased()
    }

    /// Check if two normalized texts are meaningfully different
    private func isMeaningfullyDifferent(_ new: String, from old: String) -> Bool {
        // If identical after normalization, not different
        if new == old {
            return false
        }

        // If one is empty and other isn't, that's meaningful
        if new.isEmpty != old.isEmpty {
            return true
        }

        // Check character-level difference
        let lengthDiff = abs(new.count - old.count)
        if lengthDiff >= minCharacterDifference {
            return true
        }

        // Check if any word was added/removed (not just modified)
        let newWords = Set(new.split(separator: " ").map { String($0) })
        let oldWords = Set(old.split(separator: " ").map { String($0) })
        let addedWords = newWords.subtracting(oldWords)
        let removedWords = oldWords.subtracting(newWords)

        // Meaningful if words were added or removed
        if !addedWords.isEmpty || !removedWords.isEmpty {
            return true
        }

        return false
    }
}
