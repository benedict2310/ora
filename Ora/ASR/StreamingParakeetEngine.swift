//
//  StreamingParakeetEngine.swift
//  Ora
//
//  Streaming ASR engine using FluidAudio's StreamingEouAsrManager
//

import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import os

// MARK: - Streaming ASR Managing Protocol

/// Protocol wrapper for StreamingEouAsrManager to enable testing
protocol StreamingASRManaging: Sendable {
    /// Load models from directory
    func loadModels(modelDir: URL) async throws

    /// Process audio buffer, accumulates internally
    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String

    /// Finalize and return accumulated transcript
    func finish() async throws -> String

    /// Reset state for new utterance
    func reset() async

    /// Set callback for End-of-Utterance detection
    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async

    /// Set callback for partial transcript updates
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async

    /// Whether EOU has been detected
    var eouDetected: Bool { get async }
}

// MARK: - FluidAudio Streaming Manager Wrapper

/// Production implementation wrapping FluidAudio's StreamingEouAsrManager
actor FluidAudioStreamingManager: StreamingASRManaging {
    private let manager: StreamingEouAsrManager

    init(configuration: StreamingASRConfiguration = .default) {
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .cpuAndNeuralEngine

        self.manager = StreamingEouAsrManager(
            configuration: mlConfig,
            chunkSize: configuration.chunkSize.fluidAudioChunkSize,
            eouDebounceMs: configuration.eouDebounceMs
        )
    }

    func loadModels(modelDir: URL) async throws {
        try await manager.loadModels(modelDir: modelDir)
    }

    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        try await manager.process(audioBuffer: audioBuffer)
    }

    func finish() async throws -> String {
        try await manager.finish()
    }

    func reset() async {
        await manager.reset()
    }

    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager.setEouCallback(callback)
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(callback)
    }

    var eouDetected: Bool {
        get async {
            await manager.eouDetected
        }
    }
}

// MARK: - Streaming Parakeet Engine

/// ASREngine implementation using FluidAudio's streaming mode with EOU detection.
///
/// Unlike the batch `ParakeetEngine` which reprocesses the entire buffer on each call,
/// `StreamingParakeetEngine` processes audio incrementally in 160ms or 320ms chunks,
/// maintaining decoder state across chunks for consistent transcription.
///
/// ## Key Differences from Batch Mode
///
/// - **Incremental processing**: Only new audio is processed, not the entire buffer
/// - **Built-in EOU detection**: Native end-of-utterance detection replaces VAD + timeout workarounds
/// - **Partial callbacks**: Real-time transcript updates via callback, not return values
/// - **Lower latency**: Chunks processed in ~50ms, enabling faster feedback
///
/// ## Usage
///
/// ```swift
/// let engine = StreamingParakeetEngine()
/// try await engine.prepare()
///
/// // Set up EOU callback for finalization
/// engine.onEndOfUtterance = { transcript in
///     submitTranscript(transcript)
/// }
///
/// // Process audio chunks (partials delivered via partialHandler)
/// _ = try await engine.process(buffer, language: "en")
///
/// // Or finalize manually
/// let final = try await engine.finalize(buffer, language: "en")
/// ```
final class StreamingParakeetEngine: @unchecked Sendable, ASREngine {

    // MARK: - Types

    enum StreamingError: LocalizedError {
        case notReady
        case modelsNotAvailable
        case processingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Streaming ASR engine is not ready"
            case .modelsNotAvailable:
                return "Streaming ASR models are not downloaded"
            case .processingFailed(let reason):
                return "Streaming ASR processing failed: \(reason)"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "StreamingParakeetEngine")
    private let configuration: StreamingASRConfiguration
    private let core: StreamingParakeetEngineCore
    private var partialHandler: (@Sendable (ASRPartial) -> Void)?

    /// Callback invoked when End-of-Utterance is detected.
    /// The callback receives the accumulated transcript at that point.
    var onEndOfUtterance: (@Sendable (String) -> Void)?

    // MARK: - Initialization

    init(configuration: StreamingASRConfiguration = .default) {
        self.configuration = configuration
        self.core = StreamingParakeetEngineCore(configuration: configuration)
    }

    /// Create engine with custom streaming manager (for testing)
    init(manager: any StreamingASRManaging) {
        self.configuration = .default
        self.core = StreamingParakeetEngineCore(manager: manager)
    }

    // MARK: - ASREngine Protocol

    func prepare() async throws {
        try await core.prepare()

        // Wire up partial callback
        await core.setPartialCallback { [weak self] text in
            guard let self = self else { return }
            let partial = ASRPartial(text: text, words: [])
            self.partialHandler?(partial)
        }

        // Wire up EOU callback
        await core.setEouCallback { [weak self] transcript in
            self?.onEndOfUtterance?(transcript)
        }

        logger.info("Streaming Parakeet engine ready (chunk: \(self.configuration.chunkSize.rawValue), debounce: \(self.configuration.eouDebounceMs)ms)")
    }

    func reset() async {
        await core.reset()
        logger.debug("Streaming decoder reset")
    }

    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {
        self.partialHandler = handler
    }

    /// Process audio buffer incrementally.
    ///
    /// Unlike batch mode, this does NOT return the current transcript.
    /// Partials are delivered via `setPartialHandler()` callback.
    /// Returns nil to maintain protocol compatibility.
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        _ = try await core.process(buffer: buffer)
        // Partials are delivered via callback, not return value
        return nil
    }

    /// Finalize transcription and return the complete transcript.
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        // Process any remaining audio
        _ = try await core.process(buffer: buffer)

        // Finalize to get complete transcript
        let transcript = try await core.finish()

        guard !transcript.isEmpty else { return nil }

        return ASRFinalSegment(
            text: transcript,
            words: [],
            segmentIndex: 0,
            timestamp: Date()
        )
    }
}

// MARK: - Engine Core (Actor)

private actor StreamingParakeetEngineCore {
    private let logger = Logger(subsystem: "com.ora.app", category: "StreamingParakeetEngineCore")
    private var manager: (any StreamingASRManaging)?
    private let configuration: StreamingASRConfiguration
    private let managerFactory: () async throws -> any StreamingASRManaging
    private var isReady = false

    init(configuration: StreamingASRConfiguration) {
        self.configuration = configuration
        self.managerFactory = {
            FluidAudioStreamingManager(configuration: configuration)
        }
    }

    init(manager: any StreamingASRManaging) {
        self.configuration = .default
        self.manager = manager
        self.managerFactory = { manager }
    }

    func prepare() async throws {
        guard !isReady else { return }

        // Create manager if needed
        if manager == nil {
            manager = try await managerFactory()
        }

        // Get model directory
        let modelDir = StreamingParakeetBootstrap.modelDirectory(for: configuration.chunkSize)

        // Verify models exist
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw StreamingParakeetEngine.StreamingError.modelsNotAvailable
        }

        // Load models
        try await manager?.loadModels(modelDir: modelDir)

        isReady = true
        logger.info("Streaming engine loaded models from: \(modelDir.lastPathComponent)")
    }

    func process(buffer: AVAudioPCMBuffer) async throws -> String {
        guard let manager = manager, isReady else {
            throw StreamingParakeetEngine.StreamingError.notReady
        }
        return try await manager.process(audioBuffer: buffer)
    }

    func finish() async throws -> String {
        guard let manager = manager, isReady else {
            throw StreamingParakeetEngine.StreamingError.notReady
        }
        return try await manager.finish()
    }

    func reset() async {
        await manager?.reset()
    }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager?.setPartialCallback(callback)
    }

    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager?.setEouCallback(callback)
    }
}

// MARK: - Streaming Model Bootstrap

/// Helper for locating streaming ASR model files
enum StreamingParakeetBootstrap {

    /// Get model directory for the specified chunk size
    static func modelDirectory(for chunkSize: StreamingASRConfiguration.ChunkSize) -> URL {
        let modelsBase = ModelPaths.modelsRoot
        let subPath: String

        switch chunkSize {
        case .ms160:
            subPath = "asr/parakeet-eou-streaming/160ms"
        case .ms320:
            subPath = "asr/parakeet-eou-streaming/320ms"
        }

        return modelsBase.appendingPathComponent(subPath)
    }

    /// Check if streaming models are available for the specified chunk size
    static func modelsAvailable(for chunkSize: StreamingASRConfiguration.ChunkSize) -> Bool {
        let modelDir = modelDirectory(for: chunkSize)
        let requiredFiles = ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"]

        for file in requiredFiles {
            let filePath = modelDir.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: filePath.path) {
                return false
            }
        }

        return true
    }
}
