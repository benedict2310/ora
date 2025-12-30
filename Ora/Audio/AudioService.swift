//
//  AudioService.swift
//  Ora
//
//  Coordinates audio capture with PTT lifecycle.
//

import Foundation
import os

// MARK: - AudioService State

/// Audio service states
enum AudioServiceState: Sendable, Equatable {
    case idle
    case starting
    case recording
    case stopping
    case error(AudioServiceError)

    static func == (lhs: AudioServiceState, rhs: AudioServiceState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.starting, .starting): return true
        case (.recording, .recording): return true
        case (.stopping, .stopping): return true
        case (.error, .error): return true
        default: return false
        }
    }
}

// MARK: - AudioService Errors

/// Errors that can occur during audio capture
enum AudioServiceError: Error, Sendable, LocalizedError, Equatable {
    case invalidState
    case microphoneNotAuthorized
    case captureError(String)
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "Audio service is not in a valid state for this operation."
        case .microphoneNotAuthorized:
            return "Microphone access is required. Please grant permission in System Settings."
        case .captureError(let message):
            return "Audio capture error: \(message)"
        case .alreadyRecording:
            return "Audio capture is already in progress."
        }
    }
}

// MARK: - AudioService

/// Manages audio capture for voice input with PTT lifecycle coordination.
///
/// ## Usage
/// ```swift
/// let service = AudioService.shared
///
/// // Start capturing (e.g., on hotkey press)
/// let stream = try await service.start()
/// for await frame in stream {
///     // Process audio frame
/// }
///
/// // Stop capturing (e.g., on hotkey release)
/// await service.stop()
/// ```
///
/// ## Thread Safety
/// AudioService is an actor, ensuring all state mutations are serialized.
/// The audio pipeline callbacks are forwarded safely via AsyncStream.
actor AudioService {

    // MARK: - Singleton

    static let shared = AudioService()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "AudioService")

    /// Underlying audio pipeline
    private var pipeline: AudioPipeline?

    /// Continuation for yielding audio frames
    private var framesContinuation: AsyncStream<AudioFrame>.Continuation?

    /// Current service state
    private(set) var state: AudioServiceState = .idle

    /// Sample counter for frame timestamps
    private var sampleCounter: UInt64 = 0

    /// Notification observers (nonisolated for init/deinit access)
    nonisolated(unsafe) private var hotkeyPressObserver: NSObjectProtocol?
    nonisolated(unsafe) private var hotkeyReleaseObserver: NSObjectProtocol?
    nonisolated(unsafe) private var notificationsSetUp = false

    // Configuration
    private let sampleRate = 16000
    private let frameSize = 1600  // 100ms at 16kHz

    // MARK: - Initialization

    private init() {
        setupNotificationsSync()
    }

    /// Initialize with custom pipeline (for testing)
    init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
    }

    deinit {
        removeNotificationsSync()
    }

    // MARK: - Public API

    /// Start audio capture and return frame stream
    ///
    /// - Returns: AsyncStream of audio frames
    /// - Throws: `AudioServiceError` if capture cannot start
    func start() async throws -> AsyncStream<AudioFrame> {
        // Validate state
        guard state == .idle || state.isError else {
            logger.warning("Cannot start: already in state \(String(describing: self.state))")
            throw AudioServiceError.alreadyRecording
        }

        // Check microphone permission
        let permStatus = await PermissionsManager.shared.check(.microphone)
        guard permStatus == .authorized else {
            state = .error(.microphoneNotAuthorized)
            throw AudioServiceError.microphoneNotAuthorized
        }

        state = .starting
        sampleCounter = 0

        // Create pipeline if needed
        let audioPipeline = pipeline ?? AudioPipeline()
        self.pipeline = audioPipeline

        // Create the async stream
        let stream = AsyncStream<AudioFrame> { continuation in
            self.framesContinuation = continuation

            continuation.onTermination = { @Sendable _ in
                Task { await self.handleStreamTermination() }
            }
        }

        // Set up audio callback to yield frames
        audioPipeline.onAudioChunk = { [weak self] samples in
            guard let self = self else { return }
            Task { await self.handleAudioChunk(samples) }
        }

        // Start the pipeline
        do {
            try audioPipeline.start()
            state = .recording
            logger.info("Audio capture started")
        } catch {
            state = .error(.captureError(error.localizedDescription))
            framesContinuation?.finish()
            framesContinuation = nil
            throw AudioServiceError.captureError(error.localizedDescription)
        }

        return stream
    }

    /// Stop audio capture
    func stop() async {
        guard state == .recording || state == .starting else {
            logger.debug("Stop called but not recording: \(String(describing: self.state))")
            return
        }

        state = .stopping

        pipeline?.stop()
        framesContinuation?.finish()
        framesContinuation = nil
        pipeline = nil

        state = .idle
        logger.info("Audio capture stopped")
    }

    /// Cancel immediately (for interruption)
    func cancel() async {
        framesContinuation?.finish()
        framesContinuation = nil
        pipeline?.stop()
        pipeline = nil
        state = .idle
        logger.debug("Audio capture cancelled")
    }

    /// Reset to idle state without stopping (for error recovery)
    func reset() async {
        framesContinuation?.finish()
        framesContinuation = nil
        pipeline?.stop()
        pipeline = nil
        state = .idle
        logger.debug("Audio service reset")
    }

    /// Check if currently recording
    var isRecording: Bool {
        state == .recording
    }

    // MARK: - Private: Audio Processing

    private func handleAudioChunk(_ samples: [Float]) {
        // Allow processing during .stopping to capture final flushed samples
        guard state == .recording || state == .stopping else { return }

        // Update sample counter
        sampleCounter += UInt64(samples.count)

        // Create frame and yield
        let frame = AudioFrame(
            samples: samples,
            sampleRate: sampleRate,
            timestamp: sampleCounter
        )

        framesContinuation?.yield(frame)
    }

    private func handleStreamTermination() {
        logger.debug("Frame stream terminated")
    }

    // MARK: - Private: Notifications

    /// Synchronous notification setup for use in init
    private nonisolated func setupNotificationsSync() {
        guard !notificationsSetUp else { return }
        notificationsSetUp = true

        // Listen for hotkey events
        hotkeyPressObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyDidPress,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.onHotkeyPress() }
        }

        hotkeyReleaseObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyDidRelease,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.onHotkeyRelease() }
        }
    }

    /// Synchronous notification removal for use in deinit
    private nonisolated func removeNotificationsSync() {
        if let observer = hotkeyPressObserver {
            NotificationCenter.default.removeObserver(observer)
            hotkeyPressObserver = nil
        }
        if let observer = hotkeyReleaseObserver {
            NotificationCenter.default.removeObserver(observer)
            hotkeyReleaseObserver = nil
        }
        notificationsSetUp = false
    }

    private func onHotkeyPress() async {
        // Audio start is triggered by orchestrator, not directly by hotkey
        // This is just for logging/debugging
        logger.debug("Hotkey pressed - ready for audio start")
    }

    private func onHotkeyRelease() async {
        // Stop will be triggered by orchestrator
        // This is just for logging/debugging
        logger.debug("Hotkey released - ready for audio stop")
    }
}

// MARK: - State Extension

extension AudioServiceState {
    /// Whether the state represents an error condition
    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Whether the state allows starting a new recording
    var canStart: Bool {
        switch self {
        case .idle, .error:
            return true
        case .starting, .recording, .stopping:
            return false
        }
    }
}
