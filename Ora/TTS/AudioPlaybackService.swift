//
//  AudioPlaybackService.swift
//  Ora
//
//  Manages streaming audio playback with buffering and interruption support.
//

import AVFoundation
import Foundation
import os

// MARK: - Errors

/// Audio playback errors
public enum AudioPlaybackError: LocalizedError, Sendable, Equatable {
    case notPrepared
    case engineStartFailed(String)
    case playbackTimedOut
    
    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "Audio playback not prepared. Call prepare() first."
        case .engineStartFailed(let reason):
            return "Failed to start audio engine: \(reason)"
        case .playbackTimedOut:
            return "Audio playback timed out before the scheduled audio completed."
        }
    }
}

/// Controllable callback source for deterministic playback tests; live output
/// continues to use AVAudioPlayerNode's default data-consumed completion.
protocol AudioPlaybackDriving: Sendable {
    func start()
    func schedule(_ chunk: AudioChunk, completion: @escaping @Sendable () -> Void)
    func stop()
}

// MARK: - AudioPlaybackService

/// Audio playback service for streaming TTS output
///
/// ## Usage
/// ```swift
/// let playback = AudioPlaybackService.shared
///
/// // Prepare engine (call once at startup)
/// try await playback.prepare()
///
/// // Play audio chunks from TTS
/// let chunks = ttsService.speak("Hello")
/// try await playback.play(chunks: chunks)
///
/// // Stop playback immediately
/// await playback.stop()
/// ```
///
/// ## Thread Safety
/// AudioPlaybackService is an actor, ensuring all state mutations are serialized.
/// AVAudioEngine callbacks are forwarded safely via actor isolation.
public actor AudioPlaybackService {

    private enum PlaybackMode {
        case live
        case simulated
        case controlled(any AudioPlaybackDriving)
    }

    // MARK: - Singleton

    public static let shared = AudioPlaybackService()

    // MARK: - Properties

    private let logger = Logger.ora(category: "AudioPlayback")
    private let playbackMode: PlaybackMode

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isPreparedState = false
    private var isPlaying = false
    private var playbackGeneration = 0
    private var currentLatencyContext: LegacyVoiceLatencyContext?

    /// Buffer management for jitter prevention
    /// Track scheduled vs completed buffers by duration
    private let targetBufferDuration: TimeInterval = 0.8  // 800ms jitter buffer
    private var bufferedDuration: TimeInterval = 0
    private var simulatedBufferTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingBuffers: [UUID: TimeInterval] = [:]
    private var completionWaiter: CheckedContinuation<Void, Error>?
    private let timeoutSleep: @Sendable (TimeInterval) async throws -> Void

    // MARK: - Initialization

    private init() {
        self.playbackMode = .live
        self.timeoutSleep = { try await Task.sleep(for: .seconds($0)) }
    }
    
    /// Initialize with custom engine (for testing)
    init(engine: AVAudioEngine?, playerNode: AVAudioPlayerNode?, simulateOutput: Bool = false) {
        self.timeoutSleep = { try await Task.sleep(for: .seconds($0)) }
        self.playbackMode = simulateOutput ? .simulated : .live
        self.engine = engine
        self.playerNode = playerNode
        self.isPreparedState = simulateOutput ? false : (engine != nil && playerNode != nil)
    }

    init(driver: any AudioPlaybackDriving,
         timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.playbackMode = .controlled(driver)
        self.timeoutSleep = timeoutSleep
        self.isPreparedState = true
    }

    // MARK: - Public API

    /// Check if engine is prepared
    public var isPrepared: Bool {
        isPreparedState
    }

    /// Check if currently playing
    public var playing: Bool {
        isPlaying
    }

    /// Prepare the audio playback engine
    ///
    /// Call this before first use (e.g., at app startup or when TTS is enabled).
    /// Safe to call multiple times - will return immediately if already prepared.
    public func prepare() throws {
        guard !isPreparedState else { return }

        guard case .live = playbackMode else {
            isPreparedState = true
            logger.info("Audio playback engine ready (simulated)")
            return
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)

        // Connect with output format matching Kokoro TTS (24kHz mono Float32)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(TTSService.kokoroSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioPlaybackError.engineStartFailed("Failed to create audio format")
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            throw AudioPlaybackError.engineStartFailed(error.localizedDescription)
        }

        self.engine = engine
        self.playerNode = playerNode
        self.isPreparedState = true

        logger.info("Audio playback engine ready")
    }

    /// Play audio chunks as they arrive from TTS
    ///
    /// - Parameter chunks: Async stream of audio chunks from TTSService
    /// - Throws: `AudioPlaybackError.notPrepared` if `prepare()` was not called
    ///
    /// This method will:
    /// 1. Schedule each chunk for playback as it arrives
    /// 2. Apply jitter buffering to prevent underruns
    /// 3. Wait for all audio to complete before returning
    /// 4. Handle cancellation gracefully
    public func play(
        chunks: AsyncThrowingStream<AudioChunk, Error>,
        latencyContext: LegacyVoiceLatencyContext? = nil
    ) async throws {
        guard isPreparedState else {
            if let latencyContext {
                latencyContext.observer.complete(.error, for: latencyContext.attempt, reason: "not_prepared")
            }
            throw AudioPlaybackError.notPrepared
        }

        self.stop()
        isPlaying = true
        playbackGeneration += 1
        let generation = playbackGeneration
        self.currentLatencyContext = latencyContext
        bufferedDuration = 0

        if case .live = playbackMode {
            guard let playerNode = playerNode else {
                throw AudioPlaybackError.notPrepared
            }
            playerNode.play()
        } else if case .controlled(let driver) = playbackMode {
            driver.start()
        }

        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                guard generation == self.playbackGeneration else { throw CancellationError() }

                // Skip empty marker chunks (e.g., from fallback TTS). The
                // fallback's didStart delegate is the timing boundary.
                guard !chunk.isEmpty else { continue }
                // Invalid PCM never establishes a scheduled boundary.
                guard chunk.sampleRate > 0, chunk.samples.allSatisfy({ $0.isFinite }),
                      let buffer = createBuffer(from: chunk) else { continue }
                let chunkDuration = chunk.duration
                let bufferID = UUID()
                self.pendingBuffers[bufferID] = chunkDuration
                bufferedDuration = self.pendingBuffers.values.reduce(0, +)
                if let latencyContext {
                    latencyContext.observer.bufferScheduled(bufferID, for: latencyContext.attempt)
                }
                let onConsumed: @Sendable () -> Void = { [weak self] in
                    if let latencyContext {
                        latencyContext.observer.bufferConsumed(bufferID, for: latencyContext.attempt)
                    }
                    Task { await self?.onBufferComplete(id: bufferID, generation: generation) }
                }

                switch playbackMode {
                case .live:
                    guard let playerNode = playerNode else {
                        throw AudioPlaybackError.notPrepared
                    }
                    playerNode.scheduleBuffer(buffer, completionHandler: onConsumed)
                    if let latencyContext {
                        latencyContext.observer.playbackBoundary(
                            for: latencyContext.attempt,
                            backend: .kokoro,
                            boundary: .scheduled
                        )
                    }
                case .simulated:
                    scheduleSimulatedBuffer(id: bufferID, duration: chunkDuration, completion: onConsumed)
                    if let latencyContext {
                        latencyContext.observer.playbackBoundary(
                            for: latencyContext.attempt,
                            backend: .kokoro,
                            boundary: .scheduled
                        )
                    }
                case .controlled(let driver):
                    driver.schedule(chunk, completion: onConsumed)
                    if let latencyContext {
                        latencyContext.observer.playbackBoundary(for: latencyContext.attempt, backend: .kokoro, boundary: .scheduled)
                    }
                }

                // Throttle if buffer is getting too large (2x target)
                // This prevents memory pressure from unbounded buffering
                while bufferedDuration > targetBufferDuration * 2 {
                    try await Task.sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                    guard generation == self.playbackGeneration else { throw CancellationError() }
                }
            }

            if let latencyContext {
                latencyContext.observer.streamFinished(for: latencyContext.attempt)
            }
            // Default callback means data consumed, not device-drained audio.
            try await waitForPlaybackComplete(generation: generation)
            guard generation == playbackGeneration else {
                throw CancellationError()
            }

        } catch is CancellationError {
            logger.debug("Playback cancelled")
            if let latencyContext {
                latencyContext.observer.complete(.cancelled, for: latencyContext.attempt, reason: "cancelled")
            }
            if generation == self.playbackGeneration { stop() }
            throw CancellationError()
        } catch {
            logger.error("Playback error: \(error.localizedDescription)")
            if let latencyContext {
                let reason = (error as? AudioPlaybackError) == .playbackTimedOut ? "playback_timeout" : "stream_error"
                latencyContext.observer.complete(.error, for: latencyContext.attempt, reason: reason)
            }
            if generation == self.playbackGeneration { stop() }
            throw error
        }

        isPlaying = false
        self.currentLatencyContext = nil
        if let latencyContext {
            latencyContext.observer.playbackCompleted(for: latencyContext.attempt)
        }
    }

    /// Stop playback immediately
    ///
    /// Clears all scheduled buffers and resets state.
    func stop(latencyAttempt: LegacyVoiceLatencyAttempt?) {
        guard self.currentLatencyContext?.attempt == latencyAttempt else { return }
        self.stop()
    }

    public func stop() {
        if let context = self.currentLatencyContext {
            context.observer.complete(.cancelled, for: context.attempt, reason: "stop")
        }
        self.currentLatencyContext = nil
        playbackGeneration += 1
        playerNode?.stop()
        if case .controlled(let driver) = playbackMode { driver.stop() }
        completionWaiter?.resume(throwing: CancellationError())
        completionWaiter = nil
        pendingBuffers.removeAll()
        cancelSimulatedBuffers()
        bufferedDuration = 0
        isPlaying = false
        logger.debug("Playback stopped")
    }

    /// Shutdown the audio engine
    ///
    /// Call when TTS is no longer needed (e.g., app termination).
    public func shutdown() {
        stop()
        engine?.stop()
        
        if let playerNode = playerNode {
            engine?.detach(playerNode)
        }
        
        engine = nil
        playerNode = nil
        isPreparedState = false
        logger.info("Audio playback engine shutdown")
    }

    // MARK: - Private

    /// Create AVAudioPCMBuffer from AudioChunk
    private func createBuffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(chunk.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount(chunk.samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount

        chunk.samples.withUnsafeBufferPointer { source in
            guard let dest = buffer.floatChannelData?[0] else { return }
            memcpy(dest, source.baseAddress!, chunk.samples.count * MemoryLayout<Float>.stride)
        }

        return buffer
    }

    /// Completion callbacks belong to a generation and buffer, not whichever
    /// playback happens to be current when their actor hop finally executes.
    private func onBufferComplete(id: UUID, generation: Int) {
        guard generation == self.playbackGeneration,
              self.pendingBuffers.removeValue(forKey: id) != nil else { return }
        simulatedBufferTasks[id] = nil
        bufferedDuration = self.pendingBuffers.values.reduce(0, +)
        if self.pendingBuffers.isEmpty {
            self.completionWaiter?.resume()
            self.completionWaiter = nil
        }
    }

    private func scheduleSimulatedBuffer(id: UUID, duration: TimeInterval, completion: @escaping @Sendable () -> Void) {
        simulatedBufferTasks[id] = Task {
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            completion()
        }
    }

    private func cancelSimulatedBuffers() {
        for task in simulatedBufferTasks.values {
            task.cancel()
        }
        simulatedBufferTasks.removeAll()
    }

    private func waitForPlaybackComplete(generation: Int) async throws {
        try Task.checkCancellation()
        guard generation == self.playbackGeneration else { throw CancellationError() }
        guard !self.pendingBuffers.isEmpty else { return }
        let duration = bufferedDuration + 1.0
        let sleeper = self.timeoutSleep
        let timeout = Task { [weak self] in
            do { try await sleeper(duration) }
            catch { return }
            await self?.timedOut(generation: generation)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.completionWaiter = continuation
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelWait(generation: generation) }
        }
    }

    private func timedOut(generation: Int) {
        guard generation == self.playbackGeneration else { return }
        self.completionWaiter?.resume(throwing: AudioPlaybackError.playbackTimedOut)
        self.completionWaiter = nil
    }

    private func cancelWait(generation: Int) {
        guard generation == self.playbackGeneration else { return }
        self.stop()
    }
}
