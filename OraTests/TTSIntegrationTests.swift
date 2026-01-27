//
//  TTSIntegrationTests.swift
//  OraTests
//
//  On-demand TTS integration tests that play audio.
//

import XCTest
@testable import Ora

final class TTSIntegrationTests: XCTestCase {

    private func requireTTSTestsEnabled() throws {
        let flagURL = ModelPaths.oraRoot.appendingPathComponent("run-tts-tests.flag")
        let envEnabled = ProcessInfo.processInfo.environment["RUN_TTS_TESTS"] == "1"
        if !envEnabled || !FileManager.default.fileExists(atPath: flagURL.path) {
            throw XCTSkip("Set RUN_TTS_TESTS=1 and create run-tts-tests.flag to enable audio integration tests")
        }
    }

    private func runAudioTest(text: String) async throws {
        try requireTTSTestsEnabled()

        await ModelManager.shared.ensureInitialized()

        let tts = TTSService.shared
        try await tts.prepare()

        let kokoroAvailable = await tts.kokoroAvailable
        if !kokoroAvailable {
            throw XCTSkip("Kokoro model not available. Run setup to download models.")
        }

        let playback = AudioPlaybackService.shared
        try await playback.prepare()
        defer {
            Task { await playback.stop() }
            Task { await tts.stop() }
        }

        let stream = tts.speak(text)
        try await playback.play(chunks: stream)
    }

    func test_ttsPlaysCalendarEventList() async throws {
        try await runAudioTest(text: ChunkerTestCorpus.calendarEventList)
    }

    func test_ttsPlaysBulletList() async throws {
        try await runAudioTest(text: ChunkerTestCorpus.bulletList)
    }

    func test_ttsPlaysLongResponse() async throws {
        try await runAudioTest(text: ChunkerTestCorpus.longParagraph)
    }

    func test_ttsPlaysHeaderAndCodeBlock() async throws {
        try await runAudioTest(text: ChunkerTestCorpus.headerAndCodeBlock)
    }

    func test_ttsPlaysNestedList() async throws {
        try await runAudioTest(text: ChunkerTestCorpus.nestedList)
    }

    func test_ttsPlaysFilenamesAndIdentifiers() async throws {
        try await runAudioTest(text: ChunkerTestCorpus.filenamesWithMarkdown)
    }

    func test_ttsPlaysCalendarWeekBullets() async throws {
        try await runAudioTest(text: ChunkerTestCorpus.calendarWeekBullets)
    }
}
