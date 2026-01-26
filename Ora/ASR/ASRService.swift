//
//  ASRService.swift
//  Ora
//
//  Parakeet ASR wrapper conforming to Ora protocols.
//

import Foundation
import AVFoundation
import os

// MARK: - ASR Events

/// Events emitted during transcription
enum ASREvent: Sendable, Equatable {
    case partial(text: String, stability: Float)
    case final(text: String)
}

// MARK: - ASR Servicing Protocol

/// ASR service protocol for streaming transcription
protocol ASRServicing: Sendable {
    /// Transcribe audio frames to ASR events
    /// - Parameter frames: Async stream of audio frames
    /// - Returns: Async throwing stream of ASR events
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error>

    /// Transcribe audio frames with VAD state changes
    /// - Parameters:
    ///   - frames: Async stream of audio frames
    ///   - onVADStateChange: Callback for VAD state transitions (speech started/ended)
    /// - Returns: Async throwing stream of ASR events
    func transcribe(
        frames: AsyncStream<AudioFrame>,
        onVADStateChange: @escaping @Sendable @MainActor (Bool) -> Void
    ) -> AsyncThrowingStream<ASREvent, Error>

    /// Transcribe audio frames with VAD and EOU callbacks (M.07)
    /// - Parameters:
    ///   - frames: Async stream of audio frames
    ///   - onVADStateChange: Callback for VAD state transitions (batch mode only)
    ///   - onEndOfUtterance: Callback for EOU detection (streaming mode only)
    /// - Returns: Async throwing stream of ASR events
    func transcribe(
        frames: AsyncStream<AudioFrame>,
        onVADStateChange: @escaping @Sendable @MainActor (Bool) -> Void,
        onEndOfUtterance: (@Sendable @MainActor () -> Void)?
    ) -> AsyncThrowingStream<ASREvent, Error>

    /// Reset decoder state for new session
    func reset() async
}

// MARK: - ASR Service

/// Parakeet-based ASR service providing streaming transcription.
///
/// ## Modes
///
/// **Batch Mode (default):** Uses ParakeetEngine which reprocesses the entire buffer
/// on each ~300ms cycle. Uses FluidAudioVAD + SilenceDetector for end-of-speech.
///
/// **Streaming Mode (M.07):** Uses StreamingParakeetEngine with incremental processing.
/// Only new audio is processed in 160/320ms chunks. Uses built-in EOU detection for
/// end-of-speech, eliminating VAD + timeout workarounds.
///
/// ## Usage
/// ```swift
/// let service = ASRService.shared
/// try await service.prepare()
///
/// let events = service.transcribe(frames: audioStream)
/// for try await event in events {
///     switch event {
///     case .partial(let text, _):
///         updateUI(text)
///     case .final(let text):
///         processTranscription(text)
///     }
/// }
/// ```
actor ASRService: @preconcurrency ASRServicing {

    // MARK: - Singleton

    static let shared = ASRService()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "ASRService")
    private var engine: (any ASREngine)?
    private var streamingEngine: StreamingParakeetEngine?
    private var isReady = false

    /// Whether streaming mode is enabled (M.07)
    private var useStreamingMode = false

    /// Minimum samples before first transcription attempt (160ms at 16kHz)
    private let minimumSamples = 2560

    /// Maximum audio buffer size in samples (10 minutes at 16kHz = ~19MB)
    /// Matches MacTalk's approach - accumulate all audio for accurate final transcription.
    /// FluidAudio's ChunkProcessor handles long audio internally via ~15s overlapping chunks.
    private let maxAudioBufferSamples = 9_600_000

    /// Window size for partial transcriptions (10 seconds at 16kHz)
    /// Partials only use a recent window for UI responsiveness.
    /// The full buffer is used for final transcription (accurate result).
    private let partialWindowSamples = 160_000

    /// FluidAudio neural VAD (lazily initialized on first transcription)
    /// Provides more robust speech detection than EnergyVAD (M.06 Phase 2)
    /// Only used in batch mode; streaming mode uses built-in EOU detection.
    private var fluidVAD: FluidAudioVAD?

    /// Whether FluidAudioVAD initialization was attempted
    private var fluidVADInitialized = false

    // MARK: - Initialization

    private init() {}

    /// Initialize with a custom engine (for testing)
    init(engine: any ASREngine) {
        self.engine = engine
    }

    /// Initialize with a custom streaming engine (for testing)
    init(streamingEngine: StreamingParakeetEngine) {
        self.streamingEngine = streamingEngine
        self.useStreamingMode = true
    }

    // MARK: - Public API

    /// Prepare the ASR engine (load models)
    func prepare() async throws {
        guard !isReady else { return }

        // Check settings for streaming mode (M.07)
        // Read settings on main actor to avoid Sendable issues with SwiftData
        let (streamingEnabled, debounceMs) = await MainActor.run {
            let settings = PersistenceManager.shared.settings
            return (settings.useStreamingASR, settings.eouDebounceMs)
        }
        self.useStreamingMode = streamingEnabled

        if useStreamingMode {
            logger.info("Preparing streaming ASR engine (M.07)...")

            // Check if streaming models are available
            let chunkSize = StreamingASRConfiguration.ChunkSize.ms160
            guard StreamingParakeetBootstrap.modelsAvailable(for: chunkSize) else {
                logger.warning("Streaming ASR models not available, falling back to batch mode")
                self.useStreamingMode = false
                try await prepareBatchEngine()
                return
            }

            // Create streaming engine with user's debounce setting
            let config = StreamingASRConfiguration(
                chunkSize: chunkSize,
                eouDebounceMs: debounceMs
            )
            streamingEngine = StreamingParakeetEngine(configuration: config)
            try await streamingEngine?.prepare()

            logger.info("Streaming ASR engine ready (debounce: \(debounceMs)ms)")
        } else {
            try await prepareBatchEngine()
        }

        isReady = true
    }

    /// Prepare the batch (non-streaming) ASR engine
    private func prepareBatchEngine() async throws {
        logger.info("Preparing batch ASR engine...")

        // Use injected engine if available, otherwise create ParakeetEngine
        if engine == nil {
            engine = ParakeetEngine()
        }
        try await engine?.prepare()

        logger.info("Batch ASR engine ready")
    }

    /// Transcribe audio frames to text events
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error> {
        // Default implementation without VAD callback
        return transcribe(frames: frames, onVADStateChange: { _ in })
    }

    /// Transcribe audio frames to text events with VAD state changes
    func transcribe(
        frames: AsyncStream<AudioFrame>,
        onVADStateChange: @escaping @Sendable @MainActor (Bool) -> Void
    ) -> AsyncThrowingStream<ASREvent, Error> {
        transcribe(frames: frames, onVADStateChange: onVADStateChange, onEndOfUtterance: nil)
    }

    /// Transcribe audio frames to text events with VAD and EOU callbacks.
    ///
    /// In streaming mode (M.07), `onEndOfUtterance` is called when the built-in EOU
    /// detector confirms end of speech. This replaces VAD-based finalization.
    ///
    /// - Parameters:
    ///   - frames: Audio frame stream
    ///   - onVADStateChange: Callback for VAD speech start/end (batch mode only)
    ///   - onEndOfUtterance: Callback for EOU detection (streaming mode only)
    /// - Returns: Stream of ASR events
    func transcribe(
        frames: AsyncStream<AudioFrame>,
        onVADStateChange: @escaping @Sendable @MainActor (Bool) -> Void,
        onEndOfUtterance: (@Sendable @MainActor () -> Void)?
    ) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if self.useStreamingMode {
                        try await self.runStreamingTranscription(
                            frames: frames,
                            continuation: continuation,
                            onEndOfUtterance: onEndOfUtterance
                        )
                    } else {
                        try await self.runTranscription(
                            frames: frames,
                            continuation: continuation,
                            onVADStateChange: onVADStateChange
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reset decoder state for new session
    func reset() async {
        await engine?.reset()
        await streamingEngine?.reset()
        await fluidVAD?.reset()
        logger.debug("ASR decoder reset")
    }

    // MARK: - Private

    /// Initialize or get FluidAudioVAD with settings from AppSettings
    /// Falls back to nil (triggering EnergyVAD fallback) if initialization fails
    private func getOrInitializeFluidVAD() async -> FluidAudioVAD? {
        // Return cached instance if available
        if let vad = fluidVAD {
            return vad
        }

        // Only try to initialize once
        guard !fluidVADInitialized else {
            return nil
        }
        fluidVADInitialized = true

        // Get settings from AppSettings on main thread since PersistenceManager uses MainActor context
        let (minSpeechDuration, minSilenceGap) = await MainActor.run {
            let settings = PersistenceManager.shared.settings
            return (settings.minSpeechDuration, settings.minSilenceGap)
        }

        let config = FluidAudioVADConfiguration(
            speechThreshold: 0.70,
            minSpeechDuration: minSpeechDuration,
            minSilenceGap: minSilenceGap,
            speechPadding: 0.10
        )

        let vad = FluidAudioVAD(configuration: config)

        do {
            try await vad.prepare()
            fluidVAD = vad
            logger.info("FluidAudioVAD initialized (minSpeech=\(minSpeechDuration)s, minSilence=\(minSilenceGap)s)")
            return vad
        } catch {
            logger.warning("FluidAudioVAD failed to initialize, falling back to EnergyVAD: \(error.localizedDescription)")
            return nil
        }
    }

    /// Ensure buffer has at least 1 second of audio (16000 samples) by padding with silence
    private func ensureMinimumDuration(_ samples: [Float]) -> [Float] {
        let minSamples = 16000
        if samples.count < minSamples {
            return samples + Array(repeating: Float(0), count: minSamples - samples.count)
        }
        return samples
    }

    private func runTranscription(
        frames: AsyncStream<AudioFrame>,
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation,
        onVADStateChange: @escaping @Sendable @MainActor (Bool) -> Void
    ) async throws {
        guard isReady, let engine = engine else {
            throw ASRServiceError.notReady
        }

        // Accumulate ALL audio for accurate final transcription (MacTalk approach)
        var allAudio: [Float] = []
        var lastPartialText = ""

        // Diagnostic: Track transcription session
        var frameCount = 0
        var processCount = 0
        logger.info("🎙️ Starting batch transcription session")

        // VAD for speech detection - try FluidAudioVAD first, fallback to EnergyVAD (M.06 Phase 2)
        let neuralVAD = await getOrInitializeFluidVAD()
        var energyVAD = EnergyVAD(configuration: VADConfiguration())
        var lastVADState = false

        // Transcript stabilizer to prevent jittery emissions (M.06)
        var stabilizer = TranscriptStabilizer(stabilityThreshold: 2, minCharacterDifference: 1)

        // Process frames as they arrive
        for await frame in frames {
            frameCount += 1
            allAudio.append(contentsOf: frame.samples)

            // Trim buffer if it exceeds 10 minutes (like MacTalk)
            if allAudio.count > maxAudioBufferSamples {
                let overflow = allAudio.count - maxAudioBufferSamples
                allAudio.removeFirst(overflow)
                logger.debug("Trimmed \(overflow) samples from buffer (exceeded 10 min limit)")
            }

            // Run VAD on incoming frame for fast speech detection
            // Use FluidAudioVAD (neural) if available, otherwise fall back to EnergyVAD
            var transitionType: VADTransitionType? = nil

            if let vad = neuralVAD {
                // Neural VAD (Silero-based) - more robust to noise
                do {
                    let vadResult = try await vad.process(frame.samples)
                    transitionType = vadResult.transitionType
                } catch {
                    // If neural VAD fails, fall back to energy VAD for this frame
                    logger.warning("FluidAudioVAD processing failed, using EnergyVAD fallback: \(error.localizedDescription)")
                    let energyResult = energyVAD.process(frame.samples)
                    transitionType = energyResult.transitionType
                }
            } else {
                // Fall back to energy-based VAD
                let energyResult = energyVAD.process(frame.samples)
                transitionType = energyResult.transitionType
            }

            // Report VAD state changes
            if let transition = transitionType {
                let isSpeech = transition == .speechStart
                if isSpeech != lastVADState {
                    lastVADState = isSpeech
                    await MainActor.run {
                        onVADStateChange(isSpeech)
                    }
                }
            }

            // For partials: only transcribe the recent window (last 10 seconds)
            // This is for UI responsiveness - the final will use the full buffer
            if allAudio.count >= minimumSamples {
                processCount += 1

                // Use only the recent window for partials
                let partialSamples: [Float]
                if allAudio.count > partialWindowSamples {
                    partialSamples = Array(allAudio.suffix(partialWindowSamples))
                } else {
                    partialSamples = allAudio
                }

                let paddedSamples = ensureMinimumDuration(partialSamples)

                let partial = try await engine.process(
                    samples: paddedSamples,
                    language: "en"
                )

                if let partial = partial {
                    // M.06: Use stabilizer to avoid emitting jittery partials
                    // Only emit if text has meaningfully changed
                    if stabilizer.shouldEmit(partial.text) {
                        lastPartialText = partial.text
                        continuation.yield(.partial(text: partial.text, stability: 0.8))
                        logger.debug("Emitting partial: '\(partial.text.prefix(50))...'")
                    }
                }
            }
        }

        // Session summary
        let durationSec = Double(allAudio.count) / 16000.0
        logger.info("🎙️ Session complete: \(frameCount) frames, \(processCount) partial calls, total audio: \(String(format: "%.1f", durationSec))s")

        // FINAL: Transcribe the ENTIRE accumulated audio buffer
        // FluidAudio's ChunkProcessor handles long audio via ~15s overlapping chunks internally
        if !allAudio.isEmpty {
            logger.info("🎙️ Finalizing with full audio buffer (\(allAudio.count) samples)")
            let paddedSamples = ensureMinimumDuration(allAudio)

            let final = try await engine.finalize(
                samples: paddedSamples,
                language: "en"
            )

            if let final = final, !final.text.isEmpty {
                logger.info("🎙️ Final transcription: '\(final.text.prefix(100))...'")
                continuation.yield(.final(text: final.text))
            } else {
                // Fall back to last partial if finalize returned empty
                logger.warning("Finalize returned empty, using last partial")
                if !lastPartialText.isEmpty {
                    continuation.yield(.final(text: lastPartialText))
                }
            }
        } else if !lastPartialText.isEmpty {
            // No audio, use last partial as final
            continuation.yield(.final(text: lastPartialText))
        }

        continuation.finish()
    }

    // MARK: - Streaming Mode Transcription (M.07)

    /// Run streaming transcription using StreamingParakeetEngine.
    ///
    /// Unlike batch mode, streaming mode:
    /// - Processes audio incrementally in 160/320ms chunks
    /// - Emits partials via callback during processing
    /// - Uses built-in EOU detection instead of VAD + timeouts
    private func runStreamingTranscription(
        frames: AsyncStream<AudioFrame>,
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation,
        onEndOfUtterance: (@Sendable @MainActor () -> Void)?
    ) async throws {
        guard isReady, let engine = streamingEngine else {
            throw ASRServiceError.notReady
        }

        // Use actor-isolated state tracking for thread safety
        let stateTracker = StreamingStateTracker()

        // Set up partial handler - emit partials as they arrive
        engine.setPartialHandler { [weak self] (partial: ASRPartial) in
            guard !partial.text.isEmpty else { return }

            Task {
                // Check if text has changed
                let previousText = await stateTracker.lastPartialText
                guard partial.text != previousText else { return }
                await stateTracker.setLastPartialText(partial.text)

                continuation.yield(.partial(text: partial.text, stability: 0.9))
                self?.logger.debug("Streaming partial: '\(partial.text.prefix(50))...'")
            }
        }

        // Set up EOU callback - triggers finalization
        engine.onEndOfUtterance = { (transcript: String) in
            Task {
                let alreadyTriggered = await stateTracker.eouTriggered
                guard !alreadyTriggered else { return }
                await stateTracker.setEouTriggered(true)

                await MainActor.run {
                    onEndOfUtterance?()
                }
            }
        }

        // Process audio frames as they arrive
        for await frame in frames {
            guard !Task.isCancelled else { break }

            // Convert frame to AVAudioPCMBuffer and process
            guard let buffer = Self.makePCMBuffer(samples: frame.samples) else {
                continue
            }

            do {
                // Process returns empty string; partials come via callback
                _ = try await engine.process(buffer, language: "en")
            } catch {
                logger.warning("Streaming chunk processing failed: \(error.localizedDescription)")
                // Continue processing - don't fail the entire stream for one chunk
            }
        }

        // Finalize transcription
        do {
            // Create an empty buffer for finalization (all audio already processed)
            guard let emptyBuffer = Self.makePCMBuffer(samples: [0.0]) else {
                continuation.finish()
                return
            }

            let final = try await engine.finalize(emptyBuffer, language: "en")
            let lastText = await stateTracker.lastPartialText

            if let final = final, !final.text.isEmpty {
                continuation.yield(.final(text: final.text))
                logger.info("Streaming final: '\(final.text.prefix(50))...'")
            } else if !lastText.isEmpty {
                // Fall back to last partial if finalize returned empty
                continuation.yield(.final(text: lastText))
                logger.info("Streaming final (from partial): '\(lastText.prefix(50))...'")
            }
        } catch {
            logger.error("Streaming finalization failed: \(error.localizedDescription)")
            // Still emit what we have
            let lastText = await stateTracker.lastPartialText
            if !lastText.isEmpty {
                continuation.yield(.final(text: lastText))
            }
        }

        // Reset for next session
        await engine.reset()
        continuation.finish()
    }

    // MARK: - Audio Buffer Helpers

    /// Create AVAudioPCMBuffer from Float32 samples (16kHz mono)
    private static func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.floatChannelData?[0] {
            for (index, sample) in samples.enumerated() {
                channelData[index] = sample
            }
        }

        return buffer
    }
}

// MARK: - Streaming State Tracker

/// Actor to track streaming transcription state in a thread-safe manner
private actor StreamingStateTracker {
    var lastPartialText: String = ""
    var eouTriggered: Bool = false

    func setLastPartialText(_ text: String) {
        lastPartialText = text
    }

    func setEouTriggered(_ triggered: Bool) {
        eouTriggered = triggered
    }
}

// MARK: - Errors

enum ASRServiceError: LocalizedError, Sendable {
    case notReady
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "ASR engine is not ready. Please wait for model loading."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
