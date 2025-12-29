//
//  AudioCapture.swift
//  Ora
//
//  Microphone audio capture using AVAudioEngine.
//

@preconcurrency import AVFoundation
import os

/// Microphone audio capture using AVAudioEngine.
///
/// ## Thread Safety
/// This class is marked `@unchecked Sendable` because:
/// - `AVAudioEngine` is documented as thread-safe by Apple
/// - The callback closure is only set during setup, before concurrent usage
/// - The tap callback safely passes audio buffers to the handler
///
/// ## Audio Callback
/// The `onAudioBuffer` callback is invoked from the audio render thread
/// (high-priority real-time thread). Handlers must complete quickly and
/// avoid blocking operations.
final class AudioCapture: @unchecked Sendable {

    // MARK: - Types

    enum CaptureError: Error, Sendable {
        case engineStartFailed(underlying: Error)
        case noInputNode
        case permissionDenied
        case deviceDisconnected
    }

    enum State: Sendable, Equatable {
        case idle
        case running
        case error(CaptureError)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.running, .running): return true
            case (.error, .error): return true
            default: return false
            }
        }
    }

    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let bus = 0
    private let bufferSize: AVAudioFrameCount = 2048
    private let logger = Logger(subsystem: "com.ora.app", category: "AudioCapture")

    /// Current capture state
    private(set) var state: State = .idle

    /// Callback invoked with each audio buffer from the microphone.
    ///
    /// - Important: Called from the audio render thread. Must complete quickly.
    /// - Note: `AVAudioPCMBuffer` is not Sendable, but is safe within callback scope.
    var onAudioBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// The format of audio being captured (device native format)
    var inputFormat: AVAudioFormat? {
        let format = engine.inputNode.inputFormat(forBus: bus)
        // Validate the format is usable
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return format
    }

    // MARK: - Lifecycle

    /// Start capturing audio from the microphone
    /// - Throws: `CaptureError` if capture cannot start
    func start() throws {
        guard state != .running else { return }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: bus)

        // Validate input format
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.error("Invalid input format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
            throw CaptureError.noInputNode
        }

        logger.info("Starting audio capture: \(format.sampleRate)Hz, \(format.channelCount) channels")

        // Install tap to capture audio
        // Buffer size of 2048 samples at 48kHz = ~42.6ms of audio
        inputNode.installTap(onBus: bus, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            self?.onAudioBuffer?(buffer, time)
        }

        do {
            try engine.start()
            state = .running
            logger.info("Audio capture started successfully")
        } catch {
            inputNode.removeTap(onBus: bus)
            state = .error(.engineStartFailed(underlying: error))
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            throw CaptureError.engineStartFailed(underlying: error)
        }
    }

    /// Stop capturing audio
    func stop() {
        guard state == .running else { return }

        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
        state = .idle
        logger.info("Audio capture stopped")
    }

    /// Pause capture (keeps engine prepared but not processing)
    func pause() {
        guard state == .running else { return }
        engine.pause()
        logger.debug("Audio capture paused")
    }

    /// Resume paused capture
    func resume() throws {
        guard state == .running else {
            try start()
            return
        }
        try engine.start()
        logger.debug("Audio capture resumed")
    }

    deinit {
        stop()
    }
}

// MARK: - Device Monitoring

extension AudioCapture {
    /// Set up notifications for audio device changes
    func setupDeviceNotifications(
        onDeviceChanged: @escaping @MainActor @Sendable () -> Void
    ) {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onDeviceChanged()
            }
        }
    }
}
