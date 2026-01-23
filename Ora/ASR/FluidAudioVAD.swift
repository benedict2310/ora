//
//  FluidAudioVAD.swift
//  Ora
//
//  Wrapper for FluidAudio's Silero VAD with streaming support.
//

import Foundation
import FluidAudio
import os

// MARK: - FluidAudioVAD Configuration

/// Configuration for FluidAudio Silero VAD
public struct FluidAudioVADConfiguration: Sendable {
    /// Neural network probability threshold for speech detection (0.0-1.0)
    /// Higher = more confident speech required, fewer false positives
    public var speechThreshold: Float

    /// Minimum speech duration in seconds before emitting speechStart
    /// Prevents false starts from brief noises
    public var minSpeechDuration: TimeInterval

    /// Minimum silence duration in seconds before emitting speechEnd
    /// Prevents premature cutoffs during natural pauses
    public var minSilenceGap: TimeInterval

    /// Speech padding in seconds (extends boundaries)
    public var speechPadding: TimeInterval

    public init(
        speechThreshold: Float = 0.70,
        minSpeechDuration: TimeInterval = 0.25,
        minSilenceGap: TimeInterval = 0.50,
        speechPadding: TimeInterval = 0.10
    ) {
        self.speechThreshold = speechThreshold
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceGap = minSilenceGap
        self.speechPadding = speechPadding
    }

    /// Default configuration optimized for voice assistant commands
    public static let `default` = FluidAudioVADConfiguration()

    /// Relaxed configuration for longer utterances with natural pauses
    public static let relaxed = FluidAudioVADConfiguration(
        speechThreshold: 0.65,
        minSpeechDuration: 0.20,
        minSilenceGap: 0.80,
        speechPadding: 0.15
    )

    /// Strict configuration for quick commands
    public static let strict = FluidAudioVADConfiguration(
        speechThreshold: 0.80,
        minSpeechDuration: 0.15,
        minSilenceGap: 0.40,
        speechPadding: 0.05
    )
}

// MARK: - FluidAudioVAD

/// Silero-based neural VAD using FluidAudio SDK.
///
/// Provides more robust speech detection than energy-based VAD:
/// - Neural network-based probability scoring
/// - Configurable min speech duration (prevents false starts)
/// - Configurable min silence gap (prevents premature cutoffs)
/// - State machine with hysteresis for stable transitions
///
/// ## Usage
/// ```swift
/// let vad = await FluidAudioVAD()
/// try await vad.prepare()
///
/// for audioChunk in audioStream {
///     let result = try await vad.process(audioChunk)
///     if let event = result.event {
///         switch event.kind {
///         case .speechStart: startRecording()
///         case .speechEnd: finishRecording()
///         }
///     }
/// }
/// ```
public actor FluidAudioVAD {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "FluidAudioVAD")
    private let configuration: FluidAudioVADConfiguration

    private var manager: VadManager?
    private var streamState: VadStreamState
    private var isReady = false

    /// Internal buffer for accumulating samples when input is smaller than chunk size
    private var sampleBuffer: [Float] = []

    /// Current speech state
    public private(set) var isSpeech: Bool = false

    /// Last probability from the model
    public private(set) var lastProbability: Float = 0

    // MARK: - Initialization

    /// Initialize with configuration
    public init(configuration: FluidAudioVADConfiguration = .default) {
        self.configuration = configuration
        self.streamState = VadStreamState.initial()
    }

    // MARK: - Public API

    /// Prepare the VAD (load Silero model)
    public func prepare() async throws {
        guard !isReady else { return }

        logger.info("Preparing FluidAudio VAD...")

        let vadConfig = VadConfig(
            defaultThreshold: configuration.speechThreshold,
            debugMode: false,
            computeUnits: .cpuAndNeuralEngine
        )

        do {
            manager = try await VadManager(config: vadConfig)
            isReady = true
            logger.info("FluidAudio VAD ready")
        } catch {
            logger.error("Failed to initialize VAD: \(error.localizedDescription)")
            throw error
        }
    }

    /// Process audio samples and return VAD result with potential event
    ///
    /// Handles variable-sized input by buffering samples internally.
    /// When enough samples are accumulated (4096 = 256ms at 16kHz),
    /// processes one or more chunks and returns the result from the last chunk.
    ///
    /// - Parameter samples: Audio samples (16kHz mono Float32)
    /// - Returns: Result with probability and potential speech start/end event
    public func process(_ samples: [Float]) async throws -> FluidAudioVADResult {
        guard isReady, let manager = manager else {
            throw FluidAudioVADError.notReady
        }

        // Add new samples to buffer
        sampleBuffer.append(contentsOf: samples)

        let chunkSize = VadManager.chunkSize  // 4096 samples (256ms at 16kHz)

        // If we don't have enough samples yet, return current state without processing
        guard sampleBuffer.count >= chunkSize else {
            return FluidAudioVADResult(
                isSpeech: isSpeech,
                probability: lastProbability,
                transitionType: nil
            )
        }

        let segmentConfig = VadSegmentationConfig(
            minSpeechDuration: configuration.minSpeechDuration,
            minSilenceDuration: configuration.minSilenceGap,
            maxSpeechDuration: 10.0,
            speechPadding: configuration.speechPadding
        )

        // Process all complete chunks in the buffer
        var reportedEvent: VADTransitionType? = nil

        while sampleBuffer.count >= chunkSize {
            // Extract one chunk
            let chunk = Array(sampleBuffer.prefix(chunkSize))
            sampleBuffer.removeFirst(chunkSize)

            // Process chunk
            let result = try await manager.processStreamingChunk(
                chunk,
                state: streamState,
                config: segmentConfig,
                returnSeconds: true
            )

            // Update state
            streamState = result.state
            lastProbability = result.probability

            // Track events - report the first event encountered (most important for state changes)
            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    isSpeech = true
                    if reportedEvent == nil {
                        reportedEvent = .speechStart
                    }
                    logger.debug("Speech started (prob: \(result.probability, format: .fixed(precision: 2)))")
                case .speechEnd:
                    isSpeech = false
                    if reportedEvent == nil {
                        reportedEvent = .speechEnd
                    }
                    logger.debug("Speech ended (prob: \(result.probability, format: .fixed(precision: 2)))")
                }
            }
        }

        // Return result with the first event we encountered (if any)
        return FluidAudioVADResult(
            isSpeech: isSpeech,
            probability: lastProbability,
            transitionType: reportedEvent
        )
    }

    /// Reset VAD state for new session
    public func reset() {
        streamState = VadStreamState.initial()
        sampleBuffer.removeAll()
        isSpeech = false
        lastProbability = 0
        logger.debug("VAD state reset")
    }
}

// MARK: - Result Types

/// Result from FluidAudio VAD processing
public struct FluidAudioVADResult: Sendable {
    /// Whether speech is currently detected
    public let isSpeech: Bool

    /// Neural network probability (0.0-1.0)
    public let probability: Float

    /// State transition if one occurred
    public let transitionType: VADTransitionType?
}

// MARK: - Errors

public enum FluidAudioVADError: LocalizedError, Sendable {
    case notReady
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notReady:
            return "FluidAudio VAD is not ready. Call prepare() first."
        case .processingFailed(let reason):
            return "VAD processing failed: \(reason)"
        }
    }
}
