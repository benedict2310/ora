//
//  SilenceDetector.swift
//  Ora
//
//  Detects end-of-speech using VAD-assisted detection with ASR fallback.
//

import Foundation
import os

/// Detects silence (end of speech) using a hybrid approach:
/// 1. **VAD-assisted (primary)**: Uses VAD speechEnd events with a confirmation timer
/// 2. **ASR-based (fallback)**: Monitors time since last ASR partial
///
/// The VAD-assisted approach provides much faster response times (~330ms vs ~1.9s)
/// while the ASR fallback ensures reliability when VAD events are unavailable.
///
/// ## Usage
/// ```swift
/// let detector = SilenceDetector(timeout: 1.0)
/// detector.onSilenceDetected = { self.submitTranscript() }
///
/// // Call on each ASR partial
/// detector.onPartialReceived()
///
/// // Call on VAD state changes
/// detector.onVADStateChanged(isSpeech: false)
///
/// // Cancel when user manually submits or cancels
/// detector.cancel()
/// ```
@MainActor
final class SilenceDetector {

    // MARK: - Constants

    /// Default silence timeout in seconds (reduced from 1.5s for faster response)
    static let defaultTimeout: TimeInterval = 1.0

    /// Minimum timeout allowed (0.5 seconds)
    static let minimumTimeout: TimeInterval = 0.5

    /// Maximum timeout allowed (2.0 seconds)
    static let maximumTimeout: TimeInterval = 2.0

    /// VAD confirmation delay in seconds before triggering submission
    static let vadConfirmationDelay: TimeInterval = 0.3

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "SilenceDetector")

    /// Timeout duration in seconds before silence is detected (ASR fallback)
    let timeout: TimeInterval

    /// Called when silence is detected (no partials for `timeout` seconds or VAD confirmed)
    var onSilenceDetected: (() -> Void)?

    /// Task for the ASR-based silence timer (fallback)
    private var silenceTask: Task<Void, Never>?

    /// Task for VAD confirmation timer (primary)
    private var vadConfirmationTask: Task<Void, Never>?

    /// Whether we have received at least one partial
    private var hasReceivedPartial = false

    /// Whether VAD events are being received (enables VAD-assisted mode)
    private var vadEventsReceived = false

    /// Current VAD speech state
    private var isSpeechActive = false

    // MARK: - Initialization

    /// Create a silence detector with the specified timeout
    /// - Parameter timeout: Seconds of silence before detection fires (default 1.0s)
    init(timeout: TimeInterval = SilenceDetector.defaultTimeout) {
        // Clamp timeout to valid range
        self.timeout = max(
            Self.minimumTimeout,
            min(Self.maximumTimeout, timeout)
        )
    }

    // MARK: - Public API

    /// Called when an ASR partial is received.
    /// Resets the ASR-based silence timer and cancels VAD confirmation if pending.
    func onPartialReceived() {
        // Cancel any existing ASR timer
        self.silenceTask?.cancel()
        self.silenceTask = nil

        // Cancel VAD confirmation if pending (AC-7: partial during confirmation resets)
        self.vadConfirmationTask?.cancel()
        self.vadConfirmationTask = nil

        // Mark that we've received at least one partial
        self.hasReceivedPartial = true

        // Start new ASR-based silence timer (fallback)
        self.silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.timeout ?? SilenceDetector.defaultTimeout))

                // Timer completed - silence detected via ASR fallback
                guard !Task.isCancelled else { return }

                // Only trigger if VAD hasn't already handled it
                guard let self = self else { return }

                // If VAD-assisted mode is active, don't use ASR fallback
                // (VAD confirmation timer should handle it)
                if self.vadEventsReceived && !self.isSpeechActive {
                    self.logger.debug("ASR timeout fired but VAD-assisted mode active, skipping")
                    return
                }

                self.logger.info("Silence detected after \(self.timeout)s (ASR fallback)")
                self.onSilenceDetected?()
            } catch {
                // Task was cancelled - this is expected
            }
        }

        self.logger.debug("Partial received, silence timer reset")
    }

    /// Called when VAD state changes (speech started or ended).
    /// - Parameter isSpeech: Whether speech is currently detected
    func onVADStateChanged(isSpeech: Bool) {
        // Track that we're receiving VAD events (enables VAD-assisted mode)
        self.vadEventsReceived = true
        self.isSpeechActive = isSpeech

        if isSpeech {
            // Speech started - cancel any pending confirmation (AC-5)
            self.cancelConfirmationTimer()
            self.logger.debug("VAD: speech started, confirmation cancelled")
        } else {
            // Speech ended - start confirmation timer if we have content
            if self.hasReceivedPartial {
                self.startConfirmationTimer()
                self.logger.debug("VAD: speech ended, starting confirmation timer")
            }
        }
    }

    /// Cancel the silence detection timer.
    /// Call this when the user manually submits or cancels.
    func cancel() {
        self.silenceTask?.cancel()
        self.silenceTask = nil
        self.vadConfirmationTask?.cancel()
        self.vadConfirmationTask = nil
        self.logger.debug("Silence detection cancelled")
    }

    /// Reset state for a new session.
    func reset() {
        self.cancel()
        self.hasReceivedPartial = false
        self.vadEventsReceived = false
        self.isSpeechActive = false
        self.logger.debug("Silence detector reset")
    }

    /// Whether at least one partial has been received
    var hasStartedListening: Bool {
        return self.hasReceivedPartial
    }

    /// Whether VAD-assisted mode is active (VAD events have been received)
    var isVADAssistedModeActive: Bool {
        return self.vadEventsReceived
    }

    // MARK: - Private Methods

    /// Start the VAD confirmation timer (AC-4)
    private func startConfirmationTimer() {
        // Cancel any existing confirmation
        self.vadConfirmationTask?.cancel()

        self.vadConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay))

                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                // Confirmation complete - VAD-detected silence confirmed
                self.logger.info("VAD silence confirmed after \(SilenceDetector.vadConfirmationDelay)s")

                // Cancel the ASR fallback timer since VAD handled it
                self.silenceTask?.cancel()
                self.silenceTask = nil

                self.onSilenceDetected?()
            } catch {
                // Task was cancelled - this is expected
            }
        }
    }

    /// Cancel the VAD confirmation timer
    private func cancelConfirmationTimer() {
        self.vadConfirmationTask?.cancel()
        self.vadConfirmationTask = nil
    }
}
