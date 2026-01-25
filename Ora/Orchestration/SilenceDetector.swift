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
/// 2. **No-change timeout**: Finalizes after text unchanged for 1.0s
/// 3. **ASR-based (fallback)**: Monitors time since last ASR partial
/// 4. **Hard max duration**: Forces finalize after 10s
///
/// The VAD-assisted approach provides much faster response times (~330ms vs ~1.9s)
/// while the ASR fallback ensures reliability when VAD events are unavailable.
///
/// ## Key Behavior (M.06 improvements)
/// - Once VAD detects speechEnd, partials do NOT cancel the confirmation timer
/// - No-change timeout triggers if text hasn't meaningfully changed for 1.0s
/// - Hard max duration (10s) forces finalization regardless of other signals
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

    /// No-change timeout in seconds - finalize if text unchanged for this duration
    static let noChangeTimeout: TimeInterval = 1.0

    /// Hard maximum duration in seconds - force finalize after this.
    /// This is a SAFETY NET for when VAD/ASR timeouts fail, not the primary cutoff.
    /// Normal end-of-speech is detected by VAD confirmation (0.3s), no-change timeout (1.0s),
    /// or ASR fallback timeout (1.0s). The hard max just prevents runaway recordings.
    static let hardMaxDuration: TimeInterval = 60.0

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

    /// Task for no-change timeout
    private var noChangeTask: Task<Void, Never>?

    /// Task for hard max duration timeout
    private var hardMaxTask: Task<Void, Never>?

    /// Whether we have received at least one partial
    private var hasReceivedPartial = false

    /// Whether VAD events are being received (enables VAD-assisted mode)
    private var vadEventsReceived = false

    /// Current VAD speech state
    private var isSpeechActive = false

    /// Whether VAD confirmation is in progress (partials should not cancel it)
    private var vadConfirmationInProgress = false
    
    /// Last normalized text for stability checking
    private var lastNormalizedText = ""

    /// Time when first partial was received (for hard max duration)
    private var sessionStartTime: Date?

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
    /// Resets the ASR-based silence timer. Does NOT cancel VAD confirmation once started.
    /// - Parameter text: The partial transcript text (for stability checking)
    func onPartialReceived(text: String = "") {
        // Track if text actually changed (ignore punctuation-only changes)
        let normalizedText = self.normalizeForComparison(text)
        let textChanged = normalizedText != self.lastNormalizedText
        
        if !text.isEmpty {
            if textChanged {
                self.logger.info("Partial received (changed): '\(text.prefix(50))...'")
                self.lastNormalizedText = normalizedText

                // Text changed - restart no-change timeout
                self.startNoChangeTimer()
            } else {
                self.logger.debug("Partial received (unchanged/punctuation only): '\(text.prefix(50))...'")
                // Don't reset timers for punctuation-only changes
                return
            }
        }
        
        // Cancel any existing ASR timer
        self.silenceTask?.cancel()
        self.silenceTask = nil

        // M.06: Do NOT cancel VAD confirmation once it has started
        // This prevents the jitter issue where partials keep resetting the confirmation
        // Old behavior (commented out):
        // self.vadConfirmationTask?.cancel()
        // self.vadConfirmationTask = nil

        // Mark that we've received at least one partial
        if !self.hasReceivedPartial {
            self.hasReceivedPartial = true
            self.sessionStartTime = Date()
            // Start hard max duration timer on first partial
            self.startHardMaxTimer()
        }

        // Start new ASR-based silence timer (fallback)
        self.silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.timeout ?? SilenceDetector.defaultTimeout))

                // Timer completed - silence detected via ASR fallback
                guard !Task.isCancelled else { return }

                // Only trigger if VAD hasn't already handled it
                guard let self = self else { return }

                // If VAD confirmation is in progress, let it handle the detection
                if self.vadConfirmationInProgress {
                    self.logger.debug("ASR timeout fired but VAD confirmation in progress, skipping")
                    return
                }

                // If VAD-assisted mode is active and speech has ended, don't duplicate
                if self.vadEventsReceived && !self.isSpeechActive {
                    self.logger.debug("ASR timeout fired but VAD-assisted mode active, skipping")
                    return
                }

                self.logger.info("Silence detected after \(self.timeout)s (ASR fallback)")
                self.triggerSilenceDetected(reason: "ASR fallback")
            } catch {
                // Task was cancelled - this is expected
            }
        }

        self.logger.debug("Silence timer reset")
    }
    
    /// Normalize text for comparison (strips punctuation to avoid flicker)
    private func normalizeForComparison(_ text: String) -> String {
        // Remove trailing punctuation and whitespace for comparison
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove common trailing punctuation that oscillates
        let punctuationToStrip = CharacterSet(charactersIn: ".,!?;:")
        return trimmed.trimmingCharacters(in: punctuationToStrip).lowercased()
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
        self.noChangeTask?.cancel()
        self.noChangeTask = nil
        self.hardMaxTask?.cancel()
        self.hardMaxTask = nil
        self.vadConfirmationInProgress = false
        self.logger.debug("Silence detection cancelled")
    }

    /// Reset state for a new session.
    func reset() {
        self.cancel()
        self.hasReceivedPartial = false
        self.vadEventsReceived = false
        self.isSpeechActive = false
        self.vadConfirmationInProgress = false
        self.lastNormalizedText = ""
        self.sessionStartTime = nil
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

    /// Whether VAD confirmation timer is currently running
    var isVADConfirmationInProgress: Bool {
        return self.vadConfirmationInProgress
    }

    // MARK: - Private Methods

    /// Trigger silence detection with logging
    private func triggerSilenceDetected(reason: String) {
        self.logger.info("Silence detected: \(reason)")
        // Cancel all other timers to prevent double-triggers
        self.silenceTask?.cancel()
        self.silenceTask = nil
        self.vadConfirmationTask?.cancel()
        self.vadConfirmationTask = nil
        self.noChangeTask?.cancel()
        self.noChangeTask = nil
        self.hardMaxTask?.cancel()
        self.hardMaxTask = nil
        self.vadConfirmationInProgress = false

        self.onSilenceDetected?()
    }

    /// Start the VAD confirmation timer (AC-4)
    private func startConfirmationTimer() {
        // Cancel any existing confirmation
        self.vadConfirmationTask?.cancel()

        // Mark that confirmation is in progress - partials should not cancel this
        self.vadConfirmationInProgress = true

        self.vadConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(SilenceDetector.vadConfirmationDelay))

                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                // Confirmation complete - VAD-detected silence confirmed
                self.triggerSilenceDetected(reason: "VAD confirmation (\(SilenceDetector.vadConfirmationDelay)s)")
            } catch {
                // Task was cancelled - this is expected
            }
        }
    }

    /// Cancel the VAD confirmation timer
    private func cancelConfirmationTimer() {
        self.vadConfirmationTask?.cancel()
        self.vadConfirmationTask = nil
        self.vadConfirmationInProgress = false
    }

    /// Start the no-change timeout timer
    /// Triggers if text hasn't meaningfully changed for noChangeTimeout duration
    private func startNoChangeTimer() {
        // Cancel any existing no-change timer
        self.noChangeTask?.cancel()

        self.noChangeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(SilenceDetector.noChangeTimeout))

                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                // No change detected for noChangeTimeout seconds
                self.triggerSilenceDetected(reason: "no-change timeout (\(SilenceDetector.noChangeTimeout)s)")
            } catch {
                // Task was cancelled - this is expected
            }
        }
    }

    /// Start the hard max duration timer
    /// Forces finalization after hardMaxDuration regardless of other signals.
    /// This is a SAFETY NET - normal end-of-speech uses VAD/ASR timeouts.
    private func startHardMaxTimer() {
        // Only start once per session
        guard self.hardMaxTask == nil else { return }

        self.hardMaxTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(SilenceDetector.hardMaxDuration))

                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                // Hard max duration reached - this should rarely happen
                self.logger.warning("Hard max duration (\(SilenceDetector.hardMaxDuration)s) reached - VAD/ASR timeouts may have failed")
                self.triggerSilenceDetected(reason: "hard max duration (\(SilenceDetector.hardMaxDuration)s)")
            } catch {
                // Task was cancelled - this is expected
            }
        }
    }
}
