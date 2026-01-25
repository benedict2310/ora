//
//  ParakeetEngine.swift
//  Ora
//
//  ASREngine implementation using FluidAudio Parakeet
//

import Foundation
@preconcurrency import AVFoundation
import FluidAudio
import os

final class ParakeetEngine: @unchecked Sendable, ASREngine {

    // MARK: - Properties

    private let bootstrap: ParakeetBootstrap
    private var partialHandler: (@Sendable (ASRPartial) -> Void)?
    private let core: ParakeetEngineCore

    // MARK: - Initialization

    init(bootstrap: ParakeetBootstrap = .shared) {
        self.bootstrap = bootstrap
        self.core = ParakeetEngineCore(bootstrap: bootstrap)
    }

    // MARK: - ASREngine Protocol

    func prepare() async throws {
        try await core.prepare()
    }

    func reset() async {
        await core.reset()
    }

    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {
        partialHandler = handler
    }

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        let result = try await core.transcribe(buffer: buffer)
        let words = mapWords(from: result)
        let partial = ASRPartial(text: result.text, words: words)

        // Notify handler
        partialHandler?(partial)

        return partial
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        let result = try await core.transcribe(buffer: buffer)
        let words = mapWords(from: result)
        return ASRFinalSegment(text: result.text, words: words)
    }

    // MARK: - Private Helpers

    private func mapWords(from result: ASRResult) -> [ASRWord] {
        guard let tokenTimings = result.tokenTimings else { return [] }
        return tokenTimings.map { timing in
            ASRWord(
                text: timing.token,
                startTime: timing.startTime,
                endTime: timing.endTime,
                confidence: timing.confidence
            )
        }
    }
}

// MARK: - Engine Core (Actor)

private actor ParakeetEngineCore {
    private let bootstrap: ParakeetBootstrap
    private var manager: AsrManager?

    init(bootstrap: ParakeetBootstrap) {
        self.bootstrap = bootstrap
    }

    func prepare() async throws {
        manager = try await bootstrap.ensureReady()
    }

    func reset() async {
        await bootstrap.reset()
    }

    func transcribe(buffer: AVAudioPCMBuffer) async throws -> ASRResult {
        let manager = try await bootstrap.ensureReady()
        let result = try await manager.transcribe(buffer, source: .microphone)

        // Diagnostic: Log raw FluidAudio result
        let logger = Logger(subsystem: "com.ora.app", category: "ParakeetEngineCore")
        logger.info("🔊 [DIAG] FluidAudio raw result: '\(result.text.prefix(100))'")

        return result
    }
}
