//
//  TTSService.swift
//  Ora
//
//  Kokoro TTS service with AVSpeechSynthesizer fallback
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

    private var kokoroEngine: KokoroEngining?
    private var isKokoroReady = false
    private var isSpeaking = false
    private var currentTask: Task<Void, Never>?
    
    /// Keep fallback synthesizer alive during playback
    private var fallbackSynthesizerHolder: FallbackSynthesizerHolder?

    /// Sample rate for Kokoro TTS output
    public static let kokoroSampleRate = 24000

    // MARK: - Initialization

    private init() {}

    /// Create with custom Kokoro engine (for testing)
    /// - Note: This initializer is internal for testing via @testable import
    init(kokoroEngine: KokoroEngining?) {
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
            Task {
                // Store reference to this task for cancellation support
                let synthesisTask = Task {
                    await self.runSynthesis(text: text, continuation: continuation)
                }
                await self.setCurrentTask(synthesisTask)
                await synthesisTask.value
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stop()
                }
            }
        }
    }

    /// Generate speech from streaming sentence chunks
    /// - Parameter sentences: Stream of sentence-sized text chunks
    /// - Returns: Async stream of audio chunks
    nonisolated public func speak(
        sentences: AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let synthesisTask = Task {
                    await self.runStreamingSynthesis(sentences: sentences, continuation: continuation)
                }
                await self.setCurrentTask(synthesisTask)
                await synthesisTask.value
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stop()
                }
            }
        }
    }

    /// Stop current speech synthesis
    public func stop() async {
        self.currentTask?.cancel()
        self.currentTask = nil
        self.isSpeaking = false
        
        // Stop any fallback synthesizer
        await self.fallbackSynthesizerHolder?.stop()
        self.fallbackSynthesizerHolder = nil
        
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
    
    private func setCurrentTask(_ task: Task<Void, Never>?) {
        self.currentTask = task as? Task<Void, Never>
    }

    private func runSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        self.isSpeaking = true
        defer { 
            self.isSpeaking = false
            self.currentTask = nil
        }

        // Capture current state for synthesis decision
        let useKokoro = self.isKokoroReady
        let engine = self.kokoroEngine

        if useKokoro, let engine = engine {
            let chunks = SentenceChunker.chunk(text: text)
            await self.runKokoroSynthesis(
                chunks: chunks,
                engine: engine,
                originalText: text,
                continuation: continuation
            )
        } else {
            await self.runFallbackSynthesis(text: text, continuation: continuation)
        }
    }

    private func runStreamingSynthesis(
        sentences: AsyncThrowingStream<String, Error>,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        self.isSpeaking = true
        defer {
            self.isSpeaking = false
            self.currentTask = nil
        }

        let useKokoro = self.isKokoroReady
        let engine = self.kokoroEngine

        if useKokoro, let engine = engine {
            do {
                for try await sentence in sentences {
                    try Task.checkCancellation()

                    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    let chunks = SentenceChunker.chunk(text: trimmed)
                    try await self.synthesizeKokoroChunks(
                        chunks: chunks,
                        engine: engine,
                        continuation: continuation
                    )
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                self.logger.error("Streaming Kokoro synthesis failed: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        } else {
            var combinedText = ""
            do {
                for try await sentence in sentences {
                    combinedText = self.joinTextSegments(combinedText, sentence)
                }
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let trimmed = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continuation.finish()
                return
            }
            await self.runFallbackSynthesis(text: trimmed, continuation: continuation)
        }
    }

    private func runKokoroSynthesis(
        chunks: [String],
        engine: KokoroEngining,
        originalText: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        do {
            try await self.synthesizeKokoroChunks(
                chunks: chunks,
                engine: engine,
                continuation: continuation
            )
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            self.logger.error("Kokoro synthesis failed: \(error.localizedDescription)")
            // Fall back to system TTS
            await self.runFallbackSynthesis(text: originalText, continuation: continuation)
        }
    }

    private func synthesizeKokoroChunks(
        chunks: [String],
        engine: KokoroEngining,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async throws {
        for chunk in chunks {
            let stream = await engine.synthesize(text: chunk)
            for try await samples in stream {
                try Task.checkCancellation()

                let audioChunk = AudioChunk(samples: samples, sampleRate: Self.kokoroSampleRate)
                continuation.yield(audioChunk)
            }
        }
    }

    private func runFallbackSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        self.logger.info("Using AVSpeechSynthesizer fallback")

        // Create holder that manages synthesizer lifecycle
        let holder = FallbackSynthesizerHolder()
        self.fallbackSynthesizerHolder = holder

        // Start synthesis on main actor
        await holder.speak(text: text)

        // Yield empty chunk to signal playback has started
        continuation.yield(AudioChunk.empty(sampleRate: Self.kokoroSampleRate))

        // Wait for completion or cancellation
        await withTaskCancellationHandler {
            await holder.waitForCompletion()
        } onCancel: {
            Task { @MainActor in
                holder.stop()
            }
        }

        self.fallbackSynthesizerHolder = nil
        continuation.finish()
    }

    private func joinTextSegments(_ left: String, _ right: String) -> String {
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRight.isEmpty else { return left }
        guard !left.isEmpty else { return trimmedRight }
        if left.hasSuffix(" ") {
            return left + trimmedRight
        }
        return left + " " + trimmedRight
    }
}

// MARK: - Fallback Synthesizer Holder

/// Holds AVSpeechSynthesizer and delegate to prevent premature deallocation
/// Must be accessed from MainActor for AVFoundation compatibility
@MainActor
private final class FallbackSynthesizerHolder: Sendable {
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: FallbackSynthesizerDelegate?
    private var completionContinuation: CheckedContinuation<Void, Never>?

    nonisolated init() {}

    func speak(text: String) {
        let synthesizer = AVSpeechSynthesizer()
        let delegate = FallbackSynthesizerDelegate { [weak self] in
            self?.handleCompletion()
        }
        
        synthesizer.delegate = delegate
        self.synthesizer = synthesizer
        self.delegate = delegate

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        synthesizer.speak(utterance)
    }

    func waitForCompletion() async {
        // If already finished, return immediately
        guard self.synthesizer?.isSpeaking == true else { return }
        
        await withCheckedContinuation { continuation in
            self.completionContinuation = continuation
        }
    }

    func stop() {
        self.synthesizer?.stopSpeaking(at: .immediate)
        self.handleCompletion()
    }

    private func handleCompletion() {
        self.completionContinuation?.resume()
        self.completionContinuation = nil
        self.synthesizer = nil
        self.delegate = nil
    }
}

// MARK: - Fallback Synthesizer Delegate

/// Delegate for AVSpeechSynthesizer completion callbacks
@MainActor
private final class FallbackSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onCompletion: @MainActor () -> Void

    nonisolated init(onCompletion: @escaping @MainActor () -> Void) {
        self.onCompletion = onCompletion
        super.init()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.onCompletion()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.onCompletion()
        }
    }
}
