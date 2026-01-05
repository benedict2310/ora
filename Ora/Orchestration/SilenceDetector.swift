//
//  SilenceDetector.swift
//  Ora
//
//  Detects end-of-speech by monitoring time since last ASR partial.
//

import Foundation
import os

/// Detects silence (end of speech) based on ASR partial timing.
///
/// The detector starts a timer after receiving the first ASR partial.
/// Each new partial resets the timer. When the timer fires without
/// receiving a new partial, silence is detected.
///
/// ## Usage
/// ```swift
/// let detector = SilenceDetector(timeout: 1.5)
/// detector.onSilenceDetected = { self.submitTranscript() }
///
/// // Call on each ASR partial
/// detector.onPartialReceived()
///
/// // Cancel when user manually submits or cancels
/// detector.cancel()
/// ```
@MainActor
final class SilenceDetector {

    // MARK: - Constants

    /// Default silence timeout in seconds
    static let defaultTimeout: TimeInterval = 1.5

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "SilenceDetector")

    /// Timeout duration in seconds before silence is detected
    let timeout: TimeInterval

    /// Called when silence is detected (no partials for `timeout` seconds)
    var onSilenceDetected: (() -> Void)?

    /// Task for the silence timer
    private var silenceTask: Task<Void, Never>?

    /// Whether we have received at least one partial (AC-2)
    private var hasReceivedPartial = false

    // MARK: - Initialization

    /// Create a silence detector with the specified timeout
    /// - Parameter timeout: Seconds of silence before detection fires (default 1.5s)
    init(timeout: TimeInterval = SilenceDetector.defaultTimeout) {
        self.timeout = timeout
    }

    // MARK: - Public API

    /// Called when an ASR partial is received.
    /// Resets the silence timer (AC-3).
    func onPartialReceived() {
        // Cancel any existing timer
        self.silenceTask?.cancel()
        self.silenceTask = nil

        // Mark that we've received at least one partial (AC-2)
        self.hasReceivedPartial = true

        // Start new silence timer
        self.silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.timeout ?? SilenceDetector.defaultTimeout))

                // Timer completed - silence detected
                guard !Task.isCancelled else { return }

                self?.logger.info("Silence detected after \(self?.timeout ?? 0)s")
                self?.onSilenceDetected?()
            } catch {
                // Task was cancelled - this is expected
            }
        }

        self.logger.debug("Partial received, silence timer reset")
    }

    /// Cancel the silence detection timer.
    /// Call this when the user manually submits or cancels.
    func cancel() {
        self.silenceTask?.cancel()
        self.silenceTask = nil
        self.logger.debug("Silence detection cancelled")
    }

    /// Reset state for a new session.
    func reset() {
        self.cancel()
        self.hasReceivedPartial = false
        self.logger.debug("Silence detector reset")
    }

    /// Whether at least one partial has been received
    var hasStartedListening: Bool {
        return self.hasReceivedPartial
    }
}
