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
public enum AudioPlaybackError: LocalizedError, Sendable {
    case notPrepared
    case engineStartFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "Audio playback not prepared. Call prepare() first."
        case .engineStartFailed(let reason):
            return "Failed to start audio engine: \(reason)"
        }
    }
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

    /// Buffer management for jitter prevention
    /// Track scheduled vs completed buffers by duration
    private let targetBufferDuration: TimeInterval = 0.8  // 800ms jitter buffer
    private var bufferedDuration: TimeInterval = 0
    private var simulatedBufferTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Initialization

    private init() {
        self.playbackMode = .live
    }
    
    /// Initialize with custom engine (for testing)
    init(engine: AVAudioEngine?, playerNode: AVAudioPlayerNode?, simulateOutput: Bool = false) {
        self.playbackMode = simulateOutput ? .simulated : .live
        self.engine = engine
        self.playerNode = playerNode
        self.isPreparedState = simulateOutput ? false : (engine != nil && playerNode != nil)
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

        guard playbackMode == .live else {
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
    public func play(chunks: AsyncThrowingStream<AudioChunk, Error>) async throws {
        guard isPreparedState else {
            throw AudioPlaybackError.notPrepared
        }

        isPlaying = true
        bufferedDuration = 0

        if playbackMode == .live {
            guard let playerNode = playerNode else {
                throw AudioPlaybackError.notPrepared
            }
            playerNode.play()
        }

        do {
            for try await chunk in chunks {
                try Task.checkCancellation()

                // Skip empty marker chunks (e.g., from fallback TTS)
                guard !chunk.isEmpty else { continue }

                // Schedule for playback with completion callback
                let chunkDuration = chunk.duration
                bufferedDuration += chunkDuration

                switch playbackMode {
                case .live:
                    guard let buffer = createBuffer(from: chunk) else {
                        logger.warning("Failed to create buffer from chunk")
                        bufferedDuration = max(0, bufferedDuration - chunkDuration)
                        continue
                    }
                    guard let playerNode = playerNode else {
                        throw AudioPlaybackError.notPrepared
                    }
                    playerNode.scheduleBuffer(buffer) { [weak self] in
                        Task { await self?.onBufferComplete(duration: chunkDuration) }
                    }
                case .simulated:
                    scheduleSimulatedBuffer(duration: chunkDuration)
                }

                // Throttle if buffer is getting too large (2x target)
                // This prevents memory pressure from unbounded buffering
                while bufferedDuration > targetBufferDuration * 2 {
                    try await Task.sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                }
            }

            // Wait for all scheduled audio to complete
            await waitForPlaybackComplete()

        } catch is CancellationError {
            logger.debug("Playback cancelled")
            stop()
        } catch {
            logger.error("Playback error: \(error.localizedDescription)")
            stop()
            throw error
        }

        isPlaying = false
    }

    /// Stop playback immediately
    ///
    /// Clears all scheduled buffers and resets state.
    public func stop() {
        playerNode?.stop()
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

    /// Called when a buffer finishes playing
    private func onBufferComplete(duration: TimeInterval) {
        bufferedDuration = max(0, bufferedDuration - duration)
    }

    private func scheduleSimulatedBuffer(duration: TimeInterval) {
        let bufferID = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            await self?.completeSimulatedBuffer(id: bufferID, duration: duration)
        }
        simulatedBufferTasks[bufferID] = task
    }

    private func completeSimulatedBuffer(id: UUID, duration: TimeInterval) {
        simulatedBufferTasks[id] = nil
        onBufferComplete(duration: duration)
    }

    private func cancelSimulatedBuffers() {
        for task in simulatedBufferTasks.values {
            task.cancel()
        }
        simulatedBufferTasks.removeAll()
    }

    /// Wait for all scheduled buffers to complete
    /// Includes a timeout to prevent indefinite waiting in edge cases
    private func waitForPlaybackComplete() async {
        // Maximum wait time based on buffered duration + safety margin
        let maxWaitTime = bufferedDuration + 1.0  // buffered + 1 second margin
        let startTime = Date()
        
        while bufferedDuration > 0 && isPlaying {
            // Check timeout
            if Date().timeIntervalSince(startTime) > maxWaitTime {
                logger.debug("Playback wait timeout - clearing remaining buffer")
                bufferedDuration = 0
                break
            }
            
            // Also check if playerNode actually stopped (e.g., audio hardware issue)
            if let node = playerNode, !node.isPlaying {
                bufferedDuration = 0
                break
            }
            
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
