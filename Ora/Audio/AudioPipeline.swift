//
//  AudioPipeline.swift
//  Ora
//
//  Coordinates audio capture, conversion, and buffering into a unified pipeline.
//

import AppKit
import Foundation
@preconcurrency import AVFoundation
import os

/// Coordinates audio capture, conversion, and buffering into a unified pipeline.
///
/// ## Usage
/// ```swift
/// let pipeline = AudioPipeline()
///
/// // Get notified of new audio chunks
/// pipeline.onAudioChunk = { samples in
///     engine.process(samples)
/// }
///
/// // Check permission and start
/// if await pipeline.requestPermission() {
///     try pipeline.start()
/// }
///
/// // Get buffered context for transcription
/// let context = pipeline.getAudioContext(seconds: 5.0)
/// ```
final class AudioPipeline: @unchecked Sendable {

    // MARK: - Types

    enum PipelineState: Sendable, Equatable {
        case idle
        case running
        case paused
        case error(Error)

        static func == (lhs: PipelineState, rhs: PipelineState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.running, .running): return true
            case (.paused, .paused): return true
            case (.error, .error): return true
            default: return false
            }
        }
    }

    struct Configuration: Sendable {
        /// Buffer duration in seconds (10-12 recommended)
        var bufferDuration: TimeInterval = 12.0

        /// Minimum samples to accumulate before notifying
        var chunkSize: Int = 4800  // 300ms @ 16kHz

        /// Target sample rate for output
        var targetSampleRate: Double = 16000

        public init(
            bufferDuration: TimeInterval = 12.0,
            chunkSize: Int = 4800,
            targetSampleRate: Double = 16000
        ) {
            self.bufferDuration = bufferDuration
            self.chunkSize = chunkSize
            self.targetSampleRate = targetSampleRate
        }
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let capture = AudioCapture()
    private let converter: AudioFormatConverter
    private let buffer: StreamingRingBuffer
    private let logger = Logger.ora(category: "AudioPipeline")

    /// Pending samples accumulator for chunk-based delivery
    private let pendingSamples = OSAllocatedUnfairLock<[Float]>(initialState: [])

    /// State lock for thread-safe access
    private let stateStore = OSAllocatedUnfairLock<PipelineState>(initialState: .idle)

    var state: PipelineState {
        stateStore.withLock { $0 }
    }

    /// Callback for audio chunks ready for processing
    /// Called when `chunkSize` samples have accumulated
    var onAudioChunk: (@Sendable ([Float]) -> Void)?

    // MARK: - Initialization

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.converter = AudioFormatConverter(targetSampleRate: configuration.targetSampleRate)
        self.buffer = StreamingRingBuffer(
            duration: configuration.bufferDuration,
            sampleRate: Int(configuration.targetSampleRate)
        )

        setupCapture()
    }

    private func setupCapture() {
        capture.onAudioBuffer = { [weak self] pcmBuffer, _ in
            self?.handleAudioBuffer(pcmBuffer)
        }
    }

    // MARK: - Audio Processing

    private func handleAudioBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        // Convert to 16kHz mono Float32
        guard let samples = converter.convert(buffer: pcmBuffer) else {
            return
        }

        // Add to ring buffer for context
        buffer.append(samples)

        // Accumulate for chunk-based delivery
        let (shouldNotify, chunk) = pendingSamples.withLock { pending -> (Bool, [Float]?) in
            pending.append(contentsOf: samples)

            if pending.count >= configuration.chunkSize {
                let chunk = pending
                pending.removeAll(keepingCapacity: true)
                return (true, chunk)
            }
            return (false, nil)
        }

        if shouldNotify, let chunk = chunk {
            onAudioChunk?(chunk)
        }
    }

    // MARK: - Permission

    /// Check current microphone authorization status
    func checkPermission() -> PermissionStatus {
        // Unit tests (and CI) should never try to touch real microphone hardware.
        // Our test harness sets ORA_SKIP_PERMISSION_PROMPTS=1; treat permission as not determined so
        // start()/resume() take the safe denial path without invoking AudioCapture.
        let env = ProcessInfo.processInfo.environment
        if let override = env["ORA_SKIP_PERMISSION_PROMPTS"]?.lowercased(), override == "1" || override == "true" {
            return .notDetermined
        }

        return MicrophonePermission.checkStatus()
    }

    /// Request microphone permission
    /// - Returns: true if permission granted
    func requestPermission() async -> Bool {
        let status = await MicrophonePermission.request()
        return status == .authorized
    }

    /// Open system settings to grant microphone permission
    @MainActor
    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lifecycle

    /// Start the audio pipeline
    /// - Throws: Error if capture fails to start
    func start() throws {
        guard state != .running else { return }

        // Verify permission before starting
        guard checkPermission() == .authorized else {
            throw AudioPipelineError.permissionDenied
        }

        try capture.start()
        stateStore.withLock { $0 = .running }
        logger.info("Audio pipeline started")
    }

    /// Stop the audio pipeline
    func stop() {
        capture.stop()

        // Flush any remaining samples
        let remaining = pendingSamples.withLock { pending -> [Float] in
            let samples = pending
            pending.removeAll()
            return samples
        }

        if !remaining.isEmpty {
            onAudioChunk?(remaining)
        }

        stateStore.withLock { $0 = .idle }
        logger.info("Audio pipeline stopped")
    }

    /// Pause audio capture
    func pause() {
        capture.pause()
        stateStore.withLock { $0 = .paused }
        logger.debug("Audio pipeline paused")
    }

    /// Resume audio capture
    func resume() throws {
        // Mirror start() permission gating when resuming from idle.
        // AudioCapture.resume() delegates to start() when not running, which would otherwise
        // touch audio hardware even when permission prompts are suppressed during tests.
        if state != .running, checkPermission() != .authorized {
            throw AudioPipelineError.permissionDenied
        }

        try capture.resume()
        stateStore.withLock { $0 = .running }
        logger.debug("Audio pipeline resumed")
    }

    /// Reset the audio buffer
    func resetBuffer() {
        buffer.reset()
        pendingSamples.withLock { $0.removeAll() }
        logger.debug("Audio buffer reset")
    }

    // MARK: - Audio Context

    /// Get buffered audio context for transcription
    /// - Parameter seconds: Duration of context to retrieve
    /// - Returns: Audio samples from buffer
    func getAudioContext(seconds: TimeInterval) -> [Float] {
        buffer.peek(seconds: seconds)
    }

    /// Get all buffered audio
    func getAllBufferedAudio() -> [Float] {
        buffer.peekAll()
    }

    /// Current buffer fill level (0.0 - 1.0)
    var bufferFillLevel: Double {
        buffer.fillLevel
    }

    /// Duration of audio currently buffered
    var bufferedDuration: TimeInterval {
        buffer.duration
    }
}

// MARK: - Errors

enum AudioPipelineError: Error, Sendable, LocalizedError, Equatable {
    case permissionDenied
    case captureStartFailed
    case deviceDisconnected

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission is required to capture audio."
        case .captureStartFailed:
            return "Failed to start audio capture."
        case .deviceDisconnected:
            return "Audio device disconnected."
        }
    }
}
