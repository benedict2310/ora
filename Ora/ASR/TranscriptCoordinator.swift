//
//  TranscriptCoordinator.swift
//  Ora
//
//  Coordinates audio capture, ASR, and UI updates
//

import Foundation
import os

/// Coordinates the transcription pipeline
actor TranscriptCoordinator {

    // MARK: - Singleton

    static let shared = TranscriptCoordinator()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "TranscriptCoordinator")

    private var currentTask: Task<String?, Error>?
    private var finalTranscript: String?

    // MARK: - Public API

    /// Start transcription session
    /// Returns the final transcript when complete
    func startSession() async throws -> String? {
        // Cancel any existing session
        currentTask?.cancel()

        // Reset ASR state
        await ASRService.shared.reset()

        // Start new session
        currentTask = Task {
            try await runSession()
        }

        return try await currentTask?.value
    }

    /// Cancel current session
    func cancelSession() {
        currentTask?.cancel()
        currentTask = nil

        Task {
            await AudioService.shared.cancel()
        }

        logger.debug("Session cancelled")
    }

    // MARK: - Private

    private func runSession() async throws -> String? {
        logger.info("Starting transcription session")

        // Start audio capture
        let audioStream = try await AudioService.shared.start()

        // Start transcription
        let asrStream = await ASRService.shared.transcribe(frames: audioStream)

        var lastText = ""

        // Process ASR events
        for try await event in asrStream {
            try Task.checkCancellation()

            switch event {
            case .partial(let text, _):
                lastText = text
                await updateUI(text: text, isPartial: true)

            case .final(let text):
                lastText = text
                await updateUI(text: text, isPartial: false)
            }
        }

        logger.info("Transcription complete: \(lastText.prefix(50))...")
        return lastText.isEmpty ? nil : lastText
    }

    private func updateUI(text: String, isPartial: Bool) async {
        await MainActor.run {
            OverlayWindowController.shared.model.addUserMessage(text, isPartial: isPartial)
        }
    }
}
