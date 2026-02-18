//
//  KokoroEngine.swift
//  Ora
//
//  Kokoro MLX TTS engine using KokoroSwift
//

import Foundation
import KokoroSwift
import MLX
import os

protocol KokoroEngining: Actor {
    func synthesize(text: String) -> AsyncThrowingStream<[Float], Error>
}

/// Wrapper for Kokoro MLX TTS engine
/// Provides local text-to-speech synthesis using the Kokoro model
public actor KokoroEngine: KokoroEngining {

    // MARK: - Properties

    private let logger = Logger.ora(category: "KokoroEngine")
    private let modelPath: URL
    private let voicesPath: URL
    private var tts: KokoroTTS?
    private var voiceEmbedding: MLXArray?

    /// Default voice to use (American female voice)
    private static let defaultVoiceName = "af_heart"

    // MARK: - Initialization

    /// Initialize the Kokoro engine with a model path
    /// - Parameter modelPath: Path to the Kokoro model directory
    public init(modelPath: URL) async throws {
        self.modelPath = modelPath
        self.voicesPath = modelPath.appendingPathComponent("voices")

        // Verify model files exist
        let configPath = modelPath.appendingPathComponent("config.json")
        let weightsPath = modelPath.appendingPathComponent("kokoro-v1_0.safetensors")

        guard FileManager.default.fileExists(atPath: configPath.path),
              FileManager.default.fileExists(atPath: weightsPath.path)
        else {
            throw TTSError.modelNotFound
        }

        guard FileManager.default.fileExists(atPath: voicesPath.path) else {
            throw TTSError.initializationFailed("Voices directory not found")
        }

        // Initialize the TTS engine
        // Note: KokoroTTS init is synchronous but may take time for model loading
        self.logger.info("Loading Kokoro model from \(modelPath.path)")

        self.tts = KokoroTTS(modelPath: weightsPath, g2p: .misaki)
        self.logger.info("Kokoro TTS engine initialized")

        // Load default voice embedding
        try self.loadVoice(Self.defaultVoiceName)
    }

    // MARK: - Public API

    /// Synthesize speech from text
    /// - Parameter text: Text to synthesize
    /// - Returns: Async stream of Float32 audio samples
    public func synthesize(text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.runSynthesis(text: text, continuation: continuation)
            }
        }
    }

    /// Change the voice used for synthesis
    /// - Parameter voiceName: Name of the voice file (without .safetensors extension)
    public func setVoice(_ voiceName: String) throws {
        try self.loadVoice(voiceName)
    }

    /// List available voices
    /// - Returns: Array of voice names (without extension)
    public func availableVoices() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: voicesPath.path) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".safetensors") }
            .map { String($0.dropLast(".safetensors".count)) }
            .sorted()
    }

    // MARK: - Private

    private func loadVoice(_ voiceName: String) throws {
        let voicePath = voicesPath.appendingPathComponent("\(voiceName).safetensors")

        guard FileManager.default.fileExists(atPath: voicePath.path) else {
            throw TTSError.initializationFailed("Voice file not found: \(voiceName)")
        }

        do {
            let arrays = try MLX.loadArrays(url: voicePath)

            // Extract voice tensor - could be under "voice" key or just the first tensor
            if let voice = arrays["voice"] {
                self.voiceEmbedding = voice
            } else if let first = arrays.values.first {
                self.voiceEmbedding = first
            } else {
                throw TTSError.initializationFailed("No voice embedding found in \(voiceName)")
            }

            self.logger.info("Loaded voice: \(voiceName)")
        } catch let error as TTSError {
            throw error
        } catch {
            throw TTSError.initializationFailed("Failed to load voice \(voiceName): \(error.localizedDescription)")
        }
    }

    private func runSynthesis(
        text: String,
        continuation: AsyncThrowingStream<[Float], Error>.Continuation
    ) async {
        guard let tts = self.tts else {
            continuation.finish(throwing: TTSError.initializationFailed("TTS engine not initialized"))
            return
        }

        guard let voice = self.voiceEmbedding else {
            continuation.finish(throwing: TTSError.initializationFailed("No voice loaded"))
            return
        }

        do {
            self.logger.debug("Synthesizing: \(text.prefix(50))...")

            // Acquire exclusive access to MLX Metal to prevent race conditions with LLM
            // This serializes GPU access between TTS and LLM which share the same Metal stream
            await MLXMetalGate.shared.acquire()
            
            do {
                // Synchronize GPU before starting TTS work
                Stream.gpu.synchronize()

                // Generate audio - KokoroTTS generates all audio at once (no streaming)
                let (audioBuffer, _) = try tts.generateAudio(
                    voice: voice,
                    language: Language.enUS,
                    text: text
                )

                // Synchronize to ensure TTS work is done before releasing the gate
                Stream.gpu.synchronize()
                
                // Note: GPU.clearCache() is intentionally NOT called here (M.02 optimization)
                // The 512MB cache limit allows buffer reuse for faster inference.
                // Cache is cleared at session end and when app backgrounds.
                
                // Release gate before yielding (synchronous release within actor context)
                await MLXMetalGate.shared.release()

                // Yield the audio samples as a single chunk (sentence chunking happens upstream).
                continuation.yield(audioBuffer)
                continuation.finish()

                self.logger.debug("Synthesis complete: \(audioBuffer.count) samples")
            } catch {
                // Release gate on error before rethrowing
                await MLXMetalGate.shared.release()
                throw error
            }
        } catch {
            self.logger.error("Synthesis failed: \(error.localizedDescription)")
            continuation.finish(throwing: TTSError.synthesisFailed(error.localizedDescription))
        }
    }
}
