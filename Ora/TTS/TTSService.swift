//
//  TTSService.swift
//  Ora
//
//  Kokoro TTS wrapper with AVSpeechSynthesizer fallback
//

import AVFoundation
import Foundation
import os

/// Kokoro-based TTS service with AVSpeech fallback
public actor TTSService: TTSServicing {

    // MARK: - Singleton

    public static let shared = TTSService()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "TTSService")

    private var kokoroEngine: KokoroEngine?
    private var isKokoroReady = false
    private var isSpeaking = false
    private var currentTask: Task<Void, Never>?

    /// Sample rate for Kokoro TTS output
    public static let kokoroSampleRate = 24000

    // MARK: - Initialization

    private init() {}

    /// Create with custom Kokoro engine (for testing)
    init(kokoroEngine: KokoroEngine?) {
        self.kokoroEngine = kokoroEngine
        self.isKokoroReady = kokoroEngine != nil
    }

    // MARK: - Public API

    /// Prepare TTS engine by loading the Kokoro model
    /// Call this before first use to reduce latency
    public func prepare() async throws {
        guard !self.isKokoroReady else { return }

        self.logger.info("Preparing TTS engine...")

        // Get model path from ModelManager
        let modelManager = ModelManager.shared
        guard let modelPath = await modelManager.pathForModel(.kokoro) else {
            self.logger.warning("Kokoro model not found, will use fallback")
            return
        }

        do {
            self.kokoroEngine = try await KokoroEngine(modelPath: modelPath)
            self.isKokoroReady = true
            self.logger.info("Kokoro TTS ready")
        } catch {
            self.logger.error("Failed to load Kokoro: \(error.localizedDescription)")
            // Will use fallback - don't throw
        }
    }

    /// Generate speech from text
    /// - Parameter text: Text to synthesize
    /// - Returns: Async stream of audio chunks
    nonisolated public func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runSynthesis(text: text, continuation: continuation)
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Stop current speech synthesis
    public func stop() async {
        self.currentTask?.cancel()
        self.currentTask = nil
        self.isSpeaking = false
        self.logger.debug("TTS stopped")
    }

    /// Check if TTS is currently speaking
    public var speaking: Bool {
        self.isSpeaking
    }

    /// Check if Kokoro engine is ready
    public var kokoroAvailable: Bool {
        self.isKokoroReady
    }

    // MARK: - Private

    private func runSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        self.isSpeaking = true
        defer { self.isSpeaking = false }

        // Capture current state for synthesis decision
        let useKokoro = self.isKokoroReady
        let engine = self.kokoroEngine

        if useKokoro, let engine = engine {
            await self.runKokoroSynthesis(text: text, engine: engine, continuation: continuation)
        } else {
            await self.runFallbackSynthesis(text: text, continuation: continuation)
        }
    }

    private func runKokoroSynthesis(
        text: String,
        engine: KokoroEngine,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        do {
            // Get the stream from the actor
            let stream = await engine.synthesize(text: text)
            
            for try await samples in stream {
                try Task.checkCancellation()

                let chunk = AudioChunk(samples: samples, sampleRate: Self.kokoroSampleRate)
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            self.logger.error("Kokoro synthesis failed: \(error.localizedDescription)")
            // Fall back to system TTS
            await self.runFallbackSynthesis(text: text, continuation: continuation)
        }
    }

    private func runFallbackSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        self.logger.info("Using AVSpeechSynthesizer fallback")

        // Perform fallback synthesis on main actor for AVFoundation compatibility
        await MainActor.run {
            let synthesizer = AVSpeechSynthesizer()
            let delegate = FallbackSynthesizerDelegate()
            synthesizer.delegate = delegate

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            // AVSpeechSynthesizer plays directly, doesn't provide raw audio easily
            // Yield empty chunk to signal playback has started
            continuation.yield(AudioChunk.empty(sampleRate: Self.kokoroSampleRate))

            synthesizer.speak(utterance)

            // Store delegate to keep it alive
            delegate.synthesizer = synthesizer
        }

        // Wait a short time for short utterances, then finish
        // The actual audio plays independently via AVSpeechSynthesizer
        try? await Task.sleep(for: .milliseconds(100))
        continuation.finish()
    }
}

// MARK: - Fallback Synthesizer Delegate

/// Delegate for AVSpeechSynthesizer completion tracking
private final class FallbackSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    // Keep synthesizer alive while speaking
    // Note: This is safe because we only access from MainActor context
    var synthesizer: AVSpeechSynthesizer?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        self.synthesizer = nil
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        self.synthesizer = nil
    }
}

// MARK: - Kokoro Engine

/// Wrapper for Kokoro MLX TTS engine
/// Currently a placeholder - will be implemented when kokoro-swift-mlx is available as a package
public actor KokoroEngine {
    private let modelPath: URL

    /// Initialize the Kokoro engine with a model path
    /// - Parameter modelPath: Path to the Kokoro model directory
    public init(modelPath: URL) async throws {
        self.modelPath = modelPath

        // Verify model files exist
        let configPath = modelPath.appendingPathComponent("config.json")
        let weightsPath = modelPath.appendingPathComponent("kokoro-v1_0.safetensors")

        guard FileManager.default.fileExists(atPath: configPath.path),
              FileManager.default.fileExists(atPath: weightsPath.path)
        else {
            throw TTSError.modelNotFound
        }

        // TODO: Initialize actual Kokoro model when kokoro-swift-mlx is available
        // For now, this validates the model exists but synthesis will fail
        // triggering the AVSpeechSynthesizer fallback
    }

    /// Synthesize speech from text
    /// - Parameter text: Text to synthesize
    /// - Returns: Async stream of Float32 audio samples
    public func synthesize(text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            // TODO: Implement actual Kokoro synthesis when kokoro-swift-mlx is available
            // For now, immediately finish to trigger fallback
            continuation.finish(throwing: TTSError.synthesisFailed(
                "Kokoro engine not yet integrated - using fallback"
            ))
        }
    }
}
