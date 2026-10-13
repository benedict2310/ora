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

    private let logger = Logger.ora(category: "TTSService")

    private var kokoroEngine: KokoroEngining?
    private var isKokoroReady = false
    private var isSpeaking = false
    private var currentTask: Task<Void, Never>?
    private var currentSessionID: UUID?
    private var currentLatencyContext: LegacyVoiceLatencyContext?
    
    /// Keep fallback synthesizer alive during playback
    private var fallbackSynthesizerHolder: FallbackSpeechSession?
    private let fallbackFactory: @MainActor @Sendable () -> any FallbackSpeechDriving

    /// Sample rate for Kokoro TTS output
    public static let kokoroSampleRate = 24000

    // MARK: - Initialization

    private init() {
        self.fallbackFactory = { SystemFallbackSpeechDriver() }
    }

    /// Create with custom Kokoro engine (for testing)
    /// - Note: This initializer is internal for testing via @testable import
    init(kokoroEngine: KokoroEngining?,
         fallbackFactory: @escaping @MainActor @Sendable () -> any FallbackSpeechDriving = { SystemFallbackSpeechDriver() }) {
        self.fallbackFactory = fallbackFactory
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
        self.speak(text, latencyContext: nil)
    }

    nonisolated public func speak(_ text: String, latencyContext: LegacyVoiceLatencyContext?) -> AsyncThrowingStream<AudioChunk, Error> {
        let sessionID = UUID()
        return AsyncThrowingStream { continuation in
            Task {
                await self.startSynthesis(text: text, continuation: continuation,
                                          sessionID: sessionID, latencyContext: latencyContext)
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stop(sessionID: sessionID)
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
        let sessionID = UUID()
        return AsyncThrowingStream { continuation in
            Task {
                let synthesisTask = Task {
                    await self.runStreamingSynthesis(sentences: sentences, continuation: continuation, sessionID: sessionID)
                }
                await self.setCurrentTask(synthesisTask, sessionID: sessionID)
                await synthesisTask.value
            }

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stop(sessionID: sessionID)
                }
            }
        }
    }

    /// Stop current speech synthesis
    public func stop() async {
        await self.stop(sessionID: nil)
    }

    public func stop(latencyAttempt: LegacyVoiceLatencyAttempt?) async {
        guard self.currentLatencyContext?.attempt == latencyAttempt else { return }
        await self.stop(sessionID: self.currentSessionID)
    }

    public func stop(sessionID: UUID? = nil) async {
        if let sessionID, sessionID != self.currentSessionID {
            return
        }
        if let context = self.currentLatencyContext {
            context.observer.complete(.cancelled, for: context.attempt, reason: "synthesis_stop")
        }
        self.currentLatencyContext = nil
        self.currentTask?.cancel()
        self.currentTask = nil
        self.currentSessionID = nil
        self.isSpeaking = false
        
        // Stop any fallback synthesizer
        let holder = self.fallbackSynthesizerHolder
        self.fallbackSynthesizerHolder = nil
        await holder?.stop()
        
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
    
    private func startSynthesis(text: String,
                                continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
                                sessionID: UUID, latencyContext: LegacyVoiceLatencyContext?) {
        if let latencyContext, !latencyContext.observer.isActive(latencyContext.attempt) {
            continuation.finish(throwing: CancellationError())
            return
        }
        self.currentTask?.cancel()
        self.currentLatencyContext = latencyContext
        self.currentSessionID = sessionID
        self.currentTask = Task {
            await self.runSynthesis(text: text, continuation: continuation,
                                    sessionID: sessionID, latencyContext: latencyContext)
        }
    }

    private func setCurrentTask(_ task: Task<Void, Never>?, sessionID: UUID) {
        self.currentTask = task
        self.currentSessionID = sessionID
    }

    private func clearCurrentTask(sessionID: UUID) {
        guard self.currentSessionID == sessionID else { return }
        self.currentLatencyContext = nil
        self.currentTask = nil
        self.currentSessionID = nil
    }

    private func runSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        sessionID: UUID,
        latencyContext: LegacyVoiceLatencyContext?
    ) async {
        guard self.currentSessionID == sessionID, !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        self.isSpeaking = true
        defer {
            if self.currentSessionID == sessionID {
                self.isSpeaking = false
                self.clearCurrentTask(sessionID: sessionID)
            }
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
                continuation: continuation,
                latencyContext: latencyContext
            )
        } else {
            await self.runFallbackSynthesis(text: text, continuation: continuation, latencyContext: latencyContext)
        }
    }

    private func runStreamingSynthesis(
        sentences: AsyncThrowingStream<String, Error>,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        sessionID: UUID
    ) async {
        self.isSpeaking = true
        defer {
            if self.currentSessionID == sessionID {
                self.isSpeaking = false
                self.clearCurrentTask(sessionID: sessionID)
            }
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
            await self.runFallbackSynthesis(text: trimmed, continuation: continuation, latencyContext: nil)
        }
    }

    private func runKokoroSynthesis(
        chunks: [String],
        engine: KokoroEngining,
        originalText: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        latencyContext: LegacyVoiceLatencyContext?
    ) async {
        do {
            try await self.synthesizeKokoroChunks(
                chunks: chunks,
                engine: engine,
                continuation: continuation,
                latencyContext: latencyContext
            )
            try Task.checkCancellation()
            if let latencyContext {
                latencyContext.observer.streamFinished(for: latencyContext.attempt)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            self.logger.error("Kokoro synthesis failed: \(error.localizedDescription)")
            // Fall back to system TTS
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            await self.runFallbackSynthesis(text: originalText, continuation: continuation, latencyContext: latencyContext)
        }
    }

    private func synthesizeKokoroChunks(
        chunks: [String],
        engine: KokoroEngining,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        latencyContext: LegacyVoiceLatencyContext? = nil
    ) async throws {
        for chunk in chunks {
            let stream = await engine.synthesize(text: chunk)
            for try await samples in stream {
                try Task.checkCancellation()

                let audioChunk = AudioChunk(samples: samples, sampleRate: Self.kokoroSampleRate)
                if !audioChunk.isEmpty, let latencyContext {
                    latencyContext.observer.firstPCMChunkReceived(for: latencyContext.attempt)
                }
                continuation.yield(audioChunk)
            }
        }
    }

    private func runFallbackSynthesis(
        text: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        latencyContext: LegacyVoiceLatencyContext? = nil
    ) async {
        self.logger.info("Using AVSpeechSynthesizer fallback")

        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        let sessionID = self.currentSessionID
        let driver = await self.fallbackFactory()
        guard self.currentSessionID == sessionID, !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }
        let holder = FallbackSpeechSession(driver: driver, latencyContext: latencyContext)
        self.fallbackSynthesizerHolder = holder
        if Task.isCancelled { holder.cancel() }
        await holder.speak(text: SentenceChunker.normalizeText(text))

        // Compatibility marker only: not evidence that speech has started.
        continuation.yield(AudioChunk.empty(sampleRate: Self.kokoroSampleRate))
        let result = await withTaskCancellationHandler {
            await holder.waitForCompletion()
        } onCancel: {
            holder.cancel()
            Task { await holder.stopDriver() }
        }
        if self.fallbackSynthesizerHolder === holder {
            self.fallbackSynthesizerHolder = nil
        }
        switch result {
        case .finished:
            continuation.finish()
        case .cancelled:
            continuation.finish(throwing: CancellationError())
        }

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

// MARK: - Fallback callback seam

enum FallbackSpeechResult: Sendable {
    case finished, cancelled
}

@MainActor
protocol FallbackSpeechDriving: Sendable {
    func speak(text: String, onStart: @escaping @Sendable () -> Void,
               onCompletion: @escaping @Sendable (FallbackSpeechResult) -> Void)
    func stop()
}

/// Delegate outcomes are retained even when they arrive before a waiter. The
/// source lock also fences start callbacks after finish/cancel, before any hop.
final class FallbackSpeechSession: @unchecked Sendable {
    private let driver: any FallbackSpeechDriving
    private let context: LegacyVoiceLatencyContext?
    private let lock = NSLock()
    private var result: FallbackSpeechResult?
    private var waiter: CheckedContinuation<FallbackSpeechResult, Never>?

    init(driver: any FallbackSpeechDriving, latencyContext: LegacyVoiceLatencyContext?) {
        self.driver = driver
        self.context = latencyContext
    }

    @MainActor func speak(text: String) {
        guard self.lock.withLock({ self.result == nil }) else { return }
        self.driver.speak(text: text, onStart: { [weak self] in self?.started() },
                          onCompletion: { [weak self] in self?.finish($0) })
    }

    private func started() {
        self.lock.withLock {
            guard self.result == nil, let context = self.context else { return }
            context.observer.playbackBoundary(for: context.attempt, backend: .avSpeech, boundary: .utteranceStarted)
        }
    }

    private func finish(_ result: FallbackSpeechResult) {
        self.lock.withLock {
            guard self.result == nil else { return }
            self.result = result
            if let context = self.context {
                switch result {
                case .finished: context.observer.fallbackFinished(for: context.attempt)
                case .cancelled: context.observer.complete(.cancelled, for: context.attempt, reason: "fallback_cancelled")
                }
            }
            self.waiter?.resume(returning: result)
            self.waiter = nil
        }
    }

    func waitForCompletion() async -> FallbackSpeechResult {
        await withCheckedContinuation { continuation in
            self.lock.withLock {
                if let result = self.result { continuation.resume(returning: result) }
                else { self.waiter = continuation }
            }
        }
    }

    func cancel() { self.finish(.cancelled) }
    @MainActor func stopDriver() { self.driver.stop() }
    @MainActor func stop() {
        self.cancel()
        self.driver.stop()
    }
}

@MainActor
final class SystemFallbackSpeechDriver: FallbackSpeechDriving {
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: FallbackSynthesizerDelegate?

    func speak(text: String, onStart: @escaping @Sendable () -> Void,
               onCompletion: @escaping @Sendable (FallbackSpeechResult) -> Void) {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let delegate = FallbackSynthesizerDelegate(utterance: utterance, onDidStart: onStart, onCompletion: onCompletion)
        synthesizer.delegate = delegate
        self.synthesizer = synthesizer
        self.delegate = delegate
        synthesizer.speak(utterance)
    }

    func stop() { self.synthesizer?.stopSpeaking(at: .immediate) }
}

/// Identity matching is immutable; no actor hop precedes timestamp capture.
final class FallbackSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let utterance: AVSpeechUtterance
    private let onDidStart: @Sendable () -> Void
    private let onCompletion: @Sendable (FallbackSpeechResult) -> Void

    init(utterance: AVSpeechUtterance, onDidStart: @escaping @Sendable () -> Void,
         onCompletion: @escaping @Sendable (FallbackSpeechResult) -> Void) {
        self.utterance = utterance
        self.onDidStart = onDidStart
        self.onCompletion = onCompletion
        super.init()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        self.onDidStart()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        self.onCompletion(.finished)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        self.onCompletion(.cancelled)
    }
}
