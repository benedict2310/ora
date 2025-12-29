//
//  StreamingManager.swift
//  Ora
//
//  Central orchestrator for streaming transcription.
//

import Foundation
@preconcurrency import AVFoundation
import os

// MARK: - Configuration

/// Configuration for streaming behavior
public struct StreamingConfiguration: Sendable {
    /// Hop interval in seconds (how often to process)
    public var hopInterval: TimeInterval

    /// Rolling window size in seconds
    public var windowSize: TimeInterval

    /// Minimum audio before first transcription attempt
    public var minimumAudioLength: TimeInterval

    /// Number of stable hops before auto-finalization (0 to disable)
    public var stabilityThreshold: Int

    /// Enable VAD-gated processing
    public var enableVAD: Bool

    /// VAD configuration
    public var vadConfig: VADConfiguration

    public init(
        hopInterval: TimeInterval = 0.4,
        windowSize: TimeInterval = 10.0,
        minimumAudioLength: TimeInterval = 0.5,
        stabilityThreshold: Int = 0,  // Disabled for v1 PTT mode
        enableVAD: Bool = true,
        vadConfig: VADConfiguration = VADConfiguration()
    ) {
        self.hopInterval = hopInterval
        self.windowSize = windowSize
        self.minimumAudioLength = minimumAudioLength
        self.stabilityThreshold = stabilityThreshold
        self.enableVAD = enableVAD
        self.vadConfig = vadConfig
    }
}

// MARK: - Streaming Error

/// Errors that can occur during streaming
public enum StreamingError: Error, Sendable {
    case alreadyStreaming
    case notStreaming
    case engineNotReady
    case transcriptionFailed(Error)
    case bufferOverrun
}

// MARK: - StreamingManager

/// Main streaming transcription orchestrator.
///
/// Coordinates audio buffering, VAD gating, hop timing, and diff-based
/// partial updates to provide smooth streaming transcription.
///
/// ## v1 PTT Mode
///
/// In v1, finalization is triggered by the user releasing the hotkey,
/// not by VAD-based end-of-utterance detection. VAD is used only for
/// efficiency (skipping transcription during silence).
///
/// ## Usage
///
/// ```swift
/// let manager = StreamingManager(
///     configuration: .init(),
///     engine: parakeetEngine,
///     ringBuffer: audioBuffer
/// )
///
/// manager.onPartial = { partial in
///     updateUI(with: partial.text)
/// }
///
/// manager.onFinal = { segment in
///     processTranscription(segment.text)
/// }
///
/// // On hotkey press
/// try await manager.start()
///
/// // On hotkey release
/// await manager.stop()  // Triggers finalization
/// ```
@MainActor
public final class StreamingManager {

    // MARK: - Public Properties

    /// Current streaming state
    public private(set) var isStreaming: Bool = false

    /// Callback for partial transcription updates
    public var onPartial: (@Sendable @MainActor (ASRPartial) -> Void)?

    /// Callback for finalized segments
    public var onFinal: (@Sendable @MainActor (ASRFinalSegment) -> Void)?

    /// Callback for errors during streaming
    public var onError: (@Sendable @MainActor (StreamingError) -> Void)?

    /// Callback for VAD state changes
    public var onVADStateChange: (@Sendable @MainActor (Bool) -> Void)?

    // MARK: - Private Properties

    private let configuration: StreamingConfiguration
    private let engine: ASREngine
    private let ringBuffer: StreamingRingBuffer
    private var vad: EnergyVAD
    private var differ: PartialDiffer
    private let logger = Logger(subsystem: "com.ora.asr", category: "StreamingManager")

    private var hopTimer: HopTimer?
    private let processingQueue = DispatchQueue(
        label: "com.ora.streaming.processing",
        qos: .userInteractive
    )

    private var streamStartTime: Date?
    private var currentSegmentIndex: Int = 0
    private var lastSpeechTime: Date?
    private var consecutiveStableHops: Int = 0
    private var lastPartialText: String = ""
    private var pendingSamples: [Float] = []

    // MARK: - Initialization

    /// Create a streaming manager
    /// - Parameters:
    ///   - configuration: Streaming configuration
    ///   - engine: ASR engine for transcription
    ///   - ringBuffer: Ring buffer for audio storage
    public init(
        configuration: StreamingConfiguration = StreamingConfiguration(),
        engine: ASREngine,
        ringBuffer: StreamingRingBuffer
    ) {
        self.configuration = configuration
        self.engine = engine
        self.ringBuffer = ringBuffer
        self.vad = EnergyVAD(configuration: configuration.vadConfig)
        self.differ = PartialDiffer()
    }

    // MARK: - Public Methods

    /// Start streaming transcription
    public func start() async throws {
        guard !isStreaming else {
            throw StreamingError.alreadyStreaming
        }

        // Prepare engine
        do {
            try await engine.prepare()
        } catch {
            throw StreamingError.engineNotReady
        }

        // Reset state
        resetState()

        // Start hop timer
        startHopTimer()

        isStreaming = true
        streamStartTime = Date()
        logger.info("Streaming started")
    }

    /// Stop streaming and finalize any pending transcription
    public func stop() async {
        guard isStreaming else { return }

        isStreaming = false
        stopHopTimer()

        // Finalize any pending text (PTT release)
        await finalizeCurrentSegment()

        // Reset engine for next session
        await engine.reset()

        // Reset for next session
        resetState()
        logger.info("Streaming stopped")
    }

    /// Force finalization of current segment (e.g., on user action)
    public func forceFinalize() async {
        await finalizeCurrentSegment()
    }

    // MARK: - Private Methods

    private func resetState() {
        differ.reset()
        vad.reset()
        currentSegmentIndex = 0
        lastSpeechTime = nil
        consecutiveStableHops = 0
        lastPartialText = ""
        pendingSamples = []
    }

    private func startHopTimer() {
        let timer = HopTimer(interval: configuration.hopInterval, queue: processingQueue)
        timer.onHop = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.processHop()
            }
        }
        timer.start()
        hopTimer = timer
    }

    private func stopHopTimer() {
        hopTimer?.stop()
        hopTimer = nil
    }

    private func processHop() async {
        guard isStreaming else { return }

        // Read samples from ring buffer (rolling window)
        let windowSamples = Int(configuration.windowSize * 16000)
        let samples = ringBuffer.peek(count: windowSamples)

        guard samples.count >= Int(configuration.minimumAudioLength * 16000) else {
            return // Not enough audio yet
        }

        // Run VAD on recent audio (last hop worth)
        let recentSampleCount = Int(configuration.hopInterval * 16000)
        let recentSamples = Array(samples.suffix(recentSampleCount))
        let vadResult = vad.process(recentSamples)

        // Notify VAD state changes
        if let transition = vadResult.transitionType {
            switch transition {
            case .speechStart:
                onVADStateChange?(true)
                lastSpeechTime = Date()
            case .speechEnd:
                onVADStateChange?(false)
            }
        }

        // Skip transcription during confirmed silence (if VAD enabled)
        if configuration.enableVAD && !vadResult.isSpeech && lastSpeechTime == nil {
            return
        }

        // Process through engine
        do {
            if let partial = try await engine.process(samples: samples) {
                await handlePartialResult(partial, vadResult: vadResult)
            }
        } catch {
            onError?(.transcriptionFailed(error))
            logger.error("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func handlePartialResult(_ partial: ASRPartial, vadResult: VADResult) async {
        // Run through differ
        let diffResult = differ.process(partial.text)

        // Track stability
        if partial.text == lastPartialText {
            consecutiveStableHops += 1
        } else {
            consecutiveStableHops = 0
            lastPartialText = partial.text
        }

        // Emit partial if there's text
        if !diffResult.fullText.isEmpty {
            onPartial?(partial)
        }

        // Check for stability-based finalization (if enabled)
        if configuration.stabilityThreshold > 0 {
            let shouldFinalize =
                vadResult.transitionType == .speechEnd ||
                (diffResult.isStable && consecutiveStableHops >= configuration.stabilityThreshold)

            if shouldFinalize && !diffResult.fullText.isEmpty {
                await finalizeCurrentSegment()
            }
        }
    }

    private func finalizeCurrentSegment() async {
        let text = differ.confirmedText.isEmpty ? lastPartialText : differ.confirmedText
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            return
        }

        let now = Date()
        let startTime = streamStartTime ?? now

        // Get final transcription from engine
        let samples = ringBuffer.peekAll()
        let finalResult: ASRFinalSegment?

        do {
            finalResult = try await engine.finalize(samples: samples)
        } catch {
            // Fall back to last partial text
            finalResult = ASRFinalSegment(
                text: trimmedText,
                words: []
            )
            logger.warning("Finalization failed, using last partial: \(error.localizedDescription)")
        }

        if let segment = finalResult, !segment.text.isEmpty {
            onFinal?(segment)
            logger.info("Finalized segment \(self.currentSegmentIndex): \(segment.text)")
        }

        // Reset for next segment
        currentSegmentIndex += 1
        differ.reset()
        lastSpeechTime = nil
        consecutiveStableHops = 0
        lastPartialText = ""
    }
}
