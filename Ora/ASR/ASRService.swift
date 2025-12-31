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

    /// Reset decoder state for new session
    func reset() async
}

// MARK: - ASR Service

/// Parakeet-based ASR service providing streaming transcription.
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

    /// Maximum window size in samples (10 seconds at 16kHz)
    /// Audio older than this is dropped to prevent unbounded memory growth
    private let maxWindowSamples = 160000

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

        logger.info("Preparing ASR engine...")

        // Use injected engine if available, otherwise create ParakeetEngine
        if engine == nil {
            engine = ParakeetEngine()
        }
        try await engine?.prepare()

        isReady = true
        logger.info("ASR engine ready")
    }

    /// Transcribe audio frames to text events
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runTranscription(frames: frames, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reset decoder state for new session
    func reset() async {
        await engine?.reset()
        logger.debug("ASR decoder reset")
    }

    // MARK: - Private

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
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation
    ) async throws {
        guard isReady, let engine = engine else {
            throw ASRServiceError.notReady
        }

        var accumulatedSamples: [Float] = []
        var lastPartialText = ""
        // Committed text from chunks that have rolled out of the window
        var committedText = ""

        // Process frames as they arrive
        for await frame in frames {
            accumulatedSamples.append(contentsOf: frame.samples)

            // When exceeding the max window, finalize the portion being dropped
            // and add it to committed text to preserve the full transcript
            if accumulatedSamples.count > maxWindowSamples {
                let excessCount = accumulatedSamples.count - maxWindowSamples
                let excessSamples = Array(accumulatedSamples.prefix(excessCount))

                // Finalize the audio being dropped to preserve its transcription
                if !excessSamples.isEmpty {
                    let paddedSamples = ensureMinimumDuration(excessSamples)
                    let segment = try await engine.finalize(
                        samples: paddedSamples,
                        language: "en"
                    )
                    if let segment = segment, !segment.text.isEmpty {
                        if committedText.isEmpty {
                            committedText = segment.text
                        } else {
                            committedText += " " + segment.text
                        }
                    }
                }

                accumulatedSamples.removeFirst(excessCount)
            }

            // Process when we have enough audio
            if accumulatedSamples.count >= minimumSamples {
                let paddedSamples = ensureMinimumDuration(accumulatedSamples)
                let partial = try await engine.process(
                    samples: paddedSamples,
                    language: "en"
                )

                if let partial = partial {
                    // Combine committed text with current window partial
                    let fullText: String
                    if committedText.isEmpty {
                        fullText = partial.text
                    } else if partial.text.isEmpty {
                        fullText = committedText
                    } else {
                        fullText = committedText + " " + partial.text
                    }

                    if fullText != lastPartialText {
                        lastPartialText = fullText
                        continuation.yield(.partial(text: fullText, stability: 0.8))
                    }
                }
            }
        }

        // Finalize: Combine committed text with final transcription of remaining audio
        if !accumulatedSamples.isEmpty || !committedText.isEmpty {
            var finalText = committedText

            // Finalize remaining audio in the window
            if !accumulatedSamples.isEmpty {
                let paddedSamples = ensureMinimumDuration(accumulatedSamples)
                let final = try await engine.finalize(
                    samples: paddedSamples,
                    language: "en"
                )

                if let final = final, !final.text.isEmpty {
                    if finalText.isEmpty {
                        finalText = final.text
                    } else {
                        finalText += " " + final.text
                    }
                }
            }

            if !finalText.isEmpty {
                continuation.yield(.final(text: finalText))
            }
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
