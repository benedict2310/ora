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
struct StreamingConfiguration: Sendable {
    /// Hop interval in seconds (how often to process)
    var hopInterval: TimeInterval

    /// Rolling window size in seconds
    var windowSize: TimeInterval

    /// Minimum audio before first transcription attempt
    var minimumAudioLength: TimeInterval

    /// Number of stable hops before auto-finalization (0 to disable)
    var stabilityThreshold: Int

    /// Enable VAD-gated processing
    var enableVAD: Bool

    /// VAD configuration
    var vadConfig: VADConfiguration

    init(
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
enum StreamingError: Error, Sendable {
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
final class StreamingManager {

    // MARK: - Properties

    /// Current streaming state
    private(set) var isStreaming: Bool = false

    /// Callback for partial transcription updates
    var onPartial: (@Sendable @MainActor (ASRPartial) -> Void)?

    /// Callback for finalized segments
    var onFinal: (@Sendable @MainActor (ASRFinalSegment) -> Void)?

    /// Callback for errors during streaming
    var onError: (@Sendable @MainActor (StreamingError) -> Void)?

    /// Callback for VAD state changes
    var onVADStateChange: (@Sendable @MainActor (Bool) -> Void)?

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
    private var lastEmittedText: String = ""
    private var pendingSamples: [Float] = []

    // MARK: - Initialization

    /// Create a streaming manager
    /// - Parameters:
    ///   - configuration: Streaming configuration
    ///   - engine: ASR engine for transcription
    ///   - ringBuffer: Ring buffer for audio storage
    init(
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

    // MARK: - Methods

    /// Start streaming transcription
    func start() async throws {
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
    func stop() async {
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
    func forceFinalize() async {
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
        lastEmittedText = ""
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

        // Read most recent samples from ring buffer (rolling window)
        let windowSamples = Int(configuration.windowSize * 16000)
        let samples = ringBuffer.peekLatest(count: windowSamples)

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
        // This applies both before first speech and after speech ends
        if configuration.enableVAD && !vadResult.isSpeech {
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

        // Emit partial with diffed (stable) text - only if changed
        if !diffResult.fullText.isEmpty && diffResult.fullText != lastEmittedText {
            lastEmittedText = diffResult.fullText
            let diffedPartial = ASRPartial(text: diffResult.fullText, words: partial.words)
            onPartial?(diffedPartial)
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
        var finalText = trimmedText
        var finalWords: [ASRWord] = []

        do {
            if let result = try await engine.finalize(samples: samples), !result.text.isEmpty {
                finalText = result.text
                finalWords = result.words
            }
        } catch {
            logger.warning("Finalization failed, using last partial: \(error.localizedDescription)")
        }

        // Always emit final segment if we have text
        let indexedSegment = ASRFinalSegment(
            text: finalText,
            words: finalWords,
            segmentIndex: currentSegmentIndex,
            timestamp: now
        )
        onFinal?(indexedSegment)
        logger.info("Finalized segment \(self.currentSegmentIndex): \(finalText)")

        // Reset for next segment
        currentSegmentIndex += 1
        differ.reset()
        lastSpeechTime = nil
        consecutiveStableHops = 0
        lastPartialText = ""
        lastEmittedText = ""
    }
}
