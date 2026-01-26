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

/// ASR service protocol for transcription
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

    /// Reset decoder state for new session
    func reset() async
}

// MARK: - ASR Service

/// Parakeet-based ASR service providing batch transcription.
///
/// Accumulates all audio (up to 10 minutes). Partials transcribe a recent 10-second
/// window for UI responsiveness. Final transcribes the entire buffer using FluidAudio's
/// ChunkProcessor (handles long audio via ~15s overlapping chunks).
/// Uses FluidAudioVAD + SilenceDetector for end-of-speech detection.
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
    private var isReady = false

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
    private var fluidVAD: FluidAudioVAD?

    /// Whether FluidAudioVAD initialization was attempted
    private var fluidVADInitialized = false

    // MARK: - Initialization

    private init() {}

    /// Initialize with a custom engine (for testing)
    init(engine: any ASREngine) {
        self.engine = engine
    }

    // MARK: - Public API

    /// Prepare the ASR engine (load models)
    func prepare() async throws {
        guard !isReady else { return }

        logger.info("Preparing batch ASR engine...")

        // Use injected engine if available, otherwise create ParakeetEngine
        if engine == nil {
            engine = ParakeetEngine()
        }
        try await engine?.prepare()

        logger.info("Batch ASR engine ready")
        isReady = true
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
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runTranscription(
                        frames: frames,
                        continuation: continuation,
                        onVADStateChange: onVADStateChange
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reset decoder state for new session
    func reset() async {
        await engine?.reset()
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
