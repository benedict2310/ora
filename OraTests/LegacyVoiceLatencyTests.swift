import XCTest
@testable import Ora

final class LegacyVoiceLatencyTests: XCTestCase {
    func test_distinctSourceDurationsAndOrderedDelivery() async throws {
        let fixture = VoiceLatencyFixture()
        let turn = fixture.observer.beginTurn()
        fixture.clock.set(100)
        fixture.observer.asrFinalReceived(for: turn)
        fixture.clock.set(120)
        fixture.observer.acceptedTranscript(for: turn)
        fixture.clock.set(200)
        let attempt = fixture.observer.beginAttempt(for: turn)
        fixture.clock.set(230)
        fixture.observer.firstPCMChunkReceived(for: attempt)
        fixture.clock.set(260)
        fixture.observer.playbackBoundary(for: attempt, backend: .kokoro, boundary: .scheduled)
        let buffer = UUID()
        fixture.observer.bufferScheduled(buffer, for: attempt)
        fixture.observer.streamFinished(for: attempt)
        fixture.clock.set(400)
        fixture.observer.bufferConsumed(buffer, for: attempt)
        fixture.clock.set(900) // Bookkeeping hop delay is not a source timestamp.
        fixture.observer.playbackCompleted(for: attempt)
        let events = await fixture.events()
        XCTAssertEqual(events.map(\.name), [.voiceLatencyAttemptStarted, .voiceLatencyFirstPCMReceived,
                                            .voiceLatencyBoundaryObserved, .voiceLatencyAttemptCompleted])
        XCTAssertEqual(events.map(\.sequenceNumber), [1, 2, 3, 4])
        XCTAssertEqual(events.map { $0.time.rawValue }, [200, 230, 260, 400])
        let terminal = try XCTUnwrap(events.last)
        XCTAssertEqual(integer(terminal, "ttsRequestToFirstPCMChunkMilliseconds"), 30)
        XCTAssertEqual(integer(terminal, "ttsRequestToPlaybackBoundaryMilliseconds"), 60)
        XCTAssertEqual(integer(terminal, "acceptedTranscriptToPlaybackBoundaryMilliseconds"), 140)
        XCTAssertEqual(integer(terminal, "asrFinalToPlaybackBoundaryMilliseconds"), 160)
        XCTAssertEqual(integer(terminal, "ttsRequestToCompletionMilliseconds"), 200)
        XCTAssertEqual(string(terminal, "completionBoundary"), "dataConsumed")
        XCTAssertTrue(events.flatMap(\.fields).allSatisfy { $0.visibility == .publicDebug })
    }

    func test_terminalRejectsStartPCMAndDuplicateCompletionOnSameTurn() async {
        let fixture = VoiceLatencyFixture()
        let turn = fixture.observer.beginTurn()
        let a = fixture.observer.beginAttempt(for: turn)
        fixture.observer.complete(.cancelled, for: a, reason: "stop")
        fixture.observer.firstPCMChunkReceived(for: a)
        fixture.observer.playbackBoundary(for: a, backend: .avSpeech, boundary: .utteranceStarted)
        fixture.observer.complete(.success, for: a, reason: "late")
        let b = fixture.observer.beginAttempt(for: turn)
        fixture.observer.firstPCMChunkReceived(for: a)
        fixture.observer.playbackBoundary(for: a, backend: .kokoro, boundary: .scheduled)
        fixture.observer.playbackBoundary(for: b, backend: .avSpeech, boundary: .utteranceStarted)
        fixture.observer.fallbackFinished(for: b)
        fixture.observer.playbackCompleted(for: b)
        let events = await fixture.events()
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.filter { $0.name == .voiceLatencyBoundaryObserved }.count, 1)
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled", "success"])
        XCTAssertEqual(terminals(events).last.map { string($0, "completionBoundary") }, "utteranceFinished")
        XCTAssertEqual(a.voiceTurnID, b.voiceTurnID)
        XCTAssertNotEqual(a.speechAttemptID, b.speechAttemptID)
        XCTAssertNil(events.last.flatMap { integer($0, "asrFinalToPlaybackBoundaryMilliseconds") })
        XCTAssertNil(events.last.flatMap { integer($0, "ttsRequestToFirstPCMChunkMilliseconds") })
    }

    func test_turnAttemptReplacementAndResetCloseExactlyOnce() async {
        let fixture = VoiceLatencyFixture()
        let turn = fixture.observer.beginTurn()
        let a = fixture.observer.beginAttempt(for: turn)
        _ = fixture.observer.beginAttempt(for: turn)
        let next = fixture.observer.beginTurn()
        XCTAssertNotEqual(turn, next)
        fixture.observer.asrFinalReceived(for: turn)
        fixture.observer.acceptedTranscript(for: turn)
        let b = fixture.observer.beginAttempt(for: next)
        fixture.observer.reset()
        fixture.observer.playbackBoundary(for: a, backend: .kokoro, boundary: .scheduled)
        fixture.observer.playbackBoundary(for: b, backend: .kokoro, boundary: .scheduled)
        fixture.observer.playbackCompleted(for: b)
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "reason") }, ["attempt_replaced", "turn_replaced", "reset"])
        XCTAssertEqual(events.count, 6)
    }
}

final class LegacyVoiceSourceTests: XCTestCase {
    func test_multiChunkSchedulesOnceSkipsEmptyInvalidAndCompletesDataConsumed() async throws {
        let fixture = VoiceLatencyFixture()
        let context = fixture.context()
        let scheduled = expectation(description: "three buffers scheduled")
        scheduled.expectedFulfillmentCount = 3
        let driver = VoicePlaybackDriver(onSchedule: { scheduled.fulfill() })
        let service = AudioPlaybackService(driver: driver)
        let stream = chunks([.empty(), AudioChunk(samples: [1], sampleRate: 0),
                             AudioChunk(samples: [.nan], sampleRate: 24000), pcm(), pcm(), pcm()])
        let task = Task { try await service.play(chunks: stream, latencyContext: context) }
        await fulfillment(of: [scheduled], timeout: 2)
        driver.complete(0)
        driver.complete(0) // Duplicate consumption is inert.
        driver.complete(1)
        driver.complete(2)
        try await task.value
        let events = await fixture.events()
        XCTAssertEqual(events.filter { $0.name == .voiceLatencyBoundaryObserved }.count, 1)
        XCTAssertEqual(terminals(events).count, 1)
        XCTAssertEqual(string(try XCTUnwrap(events.last), "completionBoundary"), "dataConsumed")
    }

    func test_emptyAndInvalidOnlyNeverEstablishBoundary() async throws {
        let fixture = VoiceLatencyFixture()
        let driver = VoicePlaybackDriver()
        let service = AudioPlaybackService(driver: driver)
        try await service.play(chunks: chunks([.empty(), AudioChunk(samples: [1], sampleRate: -1)]),
                               latencyContext: fixture.context())
        let events = await fixture.events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(string(try XCTUnwrap(events.last), "completionBoundary"), "unavailable")
    }

    func test_stopLateACompletionCannotDrainBOrEmitNewBoundary() async throws {
        let fixture = VoiceLatencyFixture()
        let aScheduled = expectation(description: "A scheduled")
        let bScheduled = expectation(description: "B scheduled")
        let driver = VoicePlaybackDriver(onSchedule: { count in
            (count == 1 ? aScheduled : bScheduled).fulfill()
        })
        let service = AudioPlaybackService(driver: driver)
        let a = fixture.context()
        let aStream = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        let aTask = Task { try await service.play(chunks: aStream.stream, latencyContext: a) }
        aStream.continuation.yield(pcm())
        await fulfillment(of: [aScheduled], timeout: 2)
        await service.stop()
        let b = fixture.context()
        let bTask = Task { try await service.play(chunks: chunks([pcm()]), latencyContext: b) }
        await fulfillment(of: [bScheduled], timeout: 2)
        driver.complete(0) // Callback A delivered while B is current.
        aStream.continuation.yield(pcm()) // A's suspended consumer is fenced too.
        aStream.continuation.finish()
        do { try await aTask.value; XCTFail("stopped A succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.count, 2)
        let bPlaying = await service.playing
        XCTAssertTrue(bPlaying)
        driver.complete(1)
        try await bTask.value
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled", "success"])
        XCTAssertEqual(events.filter { $0.name == .voiceLatencyBoundaryObserved }.count, 2)
    }

    func test_closedAPlaybackStartCannotReplaceActiveB() async throws {
        let fixture = VoiceLatencyFixture()
        let a = fixture.context()
        let b = fixture.context()
        let scheduled = expectation(description: "B scheduled")
        let driver = VoicePlaybackDriver(onSchedule: { scheduled.fulfill() })
        let service = AudioPlaybackService(driver: driver)
        let bTask = Task { try await service.play(chunks: chunks([pcm()]), latencyContext: b) }
        await fulfillment(of: [scheduled], timeout: 2)
        do {
            try await service.play(chunks: chunks([]), latencyContext: a)
            XCTFail("closed A startup succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        let playing = await service.playing
        XCTAssertTrue(playing)
        driver.complete(0)
        try await bTask.value
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled", "success"])
    }

    @MainActor
    func test_closedASynthesisStartCannotReplaceActiveB() async throws {
        let fixture = VoiceLatencyFixture()
        let a = fixture.context()
        let b = fixture.context()
        let requested = expectation(description: "B requested")
        let driver = VoiceFallbackDriver(onSpeak: { requested.fulfill() })
        let tts = TTSService(kokoroEngine: nil, fallbackFactory: { driver })
        let playback = AudioPlaybackService(driver: VoicePlaybackDriver())
        let bTask = Task { try await playback.play(chunks: tts.speak("B", latencyContext: b), latencyContext: b) }
        await fulfillment(of: [requested], timeout: 2)
        let finishB = driver.finishCallback
        driver.immediateCompletion = .cancelled // Bound the regression's old A path.
        do {
            for try await _ in tts.speak("A", latencyContext: a) {}
            XCTFail("closed A startup succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.speakCount, 1)
        finishB?(.finished)
        try await bTask.value
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled", "success"])
    }

    func test_timeoutAndStreamErrorAreNotSuccess() async throws {
        let fixture = VoiceLatencyFixture()
        let service = AudioPlaybackService(driver: VoicePlaybackDriver(), timeoutSleep: { _ in })
        do {
            try await service.play(chunks: chunks([pcm()]), latencyContext: fixture.context())
            XCTFail("timeout succeeded")
        } catch { XCTAssertEqual(error as? AudioPlaybackError, .playbackTimedOut) }
        enum SourceError: Error { case failed }
        let failed = AsyncThrowingStream<AudioChunk, Error> { $0.finish(throwing: SourceError.failed) }
        do {
            try await service.play(chunks: failed, latencyContext: fixture.context())
            XCTFail("error succeeded")
        } catch { XCTAssertTrue(error is SourceError) }
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["error", "error"])
        XCTAssertEqual(terminals(events).map { string($0, "reason") }, ["playback_timeout", "stream_error"])
    }

    func test_taskCancellationDuringDrainIsExactlyOneCancelledTerminal() async throws {
        let fixture = VoiceLatencyFixture()
        let scheduled = expectation(description: "scheduled")
        let driver = VoicePlaybackDriver(onSchedule: { scheduled.fulfill() })
        let service = AudioPlaybackService(driver: driver)
        let context = fixture.context()
        let task = Task { try await service.play(chunks: chunks([pcm()]), latencyContext: context) }
        await fulfillment(of: [scheduled], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("cancel succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        driver.complete(0)
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled"])
    }

    func test_kokoroReceivesFirstNonemptyPCMAtSourceBeforePlayback() async throws {
        let fixture = VoiceLatencyFixture()
        let context = fixture.context()
        let service = TTSService(kokoroEngine: VoiceKokoroEngine())
        var count = 0
        for try await _ in service.speak("Test.", latencyContext: context) { count += 1 }
        XCTAssertEqual(count, 3)
        let events = await fixture.events()
        XCTAssertEqual(events.map(\.name), [.voiceLatencyAttemptStarted, .voiceLatencyFirstPCMReceived])
        XCTAssertEqual(integer(try XCTUnwrap(events.last), "ttsRequestToFirstPCMChunkMilliseconds"), 0)
        fixture.observer.reset()
    }

    @MainActor
    func test_fallbackStartFinishAndCancelBeforeStartUseControllableDelegate() async throws {
        let fixture = VoiceLatencyFixture()
        let driver = VoiceFallbackDriver()
        let context = fixture.context()
        let session = FallbackSpeechSession(driver: driver, latencyContext: context)
        session.speak(text: "Test")
        let requestedEvents = await fixture.events()
        XCTAssertEqual(requestedEvents.count, 1) // speak is not didStart.
        driver.startCallback?()
        driver.startCallback?()
        driver.finishCallback?(.finished) // Finish before waiter is retained.
        let result = await session.waitForCompletion()
        if case .cancelled = result { XCTFail("finish was cancellation") }
        fixture.observer.playbackCompleted(for: context.attempt)
        driver.startCallback?() // No start after terminal.
        driver.finishCallback?(.cancelled)
        var events = await fixture.events()
        XCTAssertEqual(events.map(\.name), [.voiceLatencyAttemptStarted, .voiceLatencyBoundaryObserved, .voiceLatencyAttemptCompleted])
        XCTAssertEqual(string(try XCTUnwrap(events.last), "completionBoundary"), "utteranceFinished")
        XCTAssertNil(integer(try XCTUnwrap(events.last), "ttsRequestToFirstPCMChunkMilliseconds"))

        let cancelled = fixture.context()
        let stopped = FallbackSpeechSession(driver: driver, latencyContext: cancelled)
        stopped.speak(text: "Test")
        driver.finishCallback?(.cancelled)
        driver.startCallback?()
        if case .finished = await stopped.waitForCompletion() { XCTFail("cancel was finish") }
        fixture.observer.complete(.cancelled, for: cancelled.attempt, reason: "cancelled")
        events = await fixture.events()
        XCTAssertEqual(events.filter { $0.name == .voiceLatencyBoundaryObserved }.count, 1)
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["success", "cancelled"])
    }

    @MainActor
    func test_fallbackTTSStartAndFinishPropagateWithoutPCMOrBookkeepingDelay() async throws {
        let fixture = VoiceLatencyFixture()
        let requested = expectation(description: "fallback requested")
        let driver = VoiceFallbackDriver(onSpeak: { requested.fulfill() })
        let tts = TTSService(kokoroEngine: nil, fallbackFactory: { driver })
        let playback = AudioPlaybackService(driver: VoicePlaybackDriver())
        let context = fixture.context()
        let task = Task { try await playback.play(chunks: tts.speak("Test", latencyContext: context), latencyContext: context) }
        await fulfillment(of: [requested], timeout: 2)
        let beforeStart = await fixture.events()
        XCTAssertEqual(beforeStart.map(\.name), [.voiceLatencyAttemptStarted])
        fixture.clock.set(230)
        driver.startCallback?()
        fixture.clock.set(400)
        driver.finishCallback?(.finished)
        fixture.clock.set(900)
        try await task.value
        let events = await fixture.events()
        XCTAssertEqual(events.map(\.name), [.voiceLatencyAttemptStarted, .voiceLatencyBoundaryObserved, .voiceLatencyAttemptCompleted])
        let terminal = try XCTUnwrap(events.last)
        XCTAssertEqual(terminal.time.rawValue, 400)
        XCTAssertEqual(integer(terminal, "ttsRequestToPlaybackBoundaryMilliseconds"), 130)
        XCTAssertEqual(integer(terminal, "ttsRequestToCompletionMilliseconds"), 300)
        XCTAssertNil(integer(terminal, "ttsRequestToFirstPCMChunkMilliseconds"))
        XCTAssertEqual(string(terminal, "completionBoundary"), "utteranceFinished")
        driver.finishCallback?(.cancelled)
        driver.startCallback?()
        let unchanged = await fixture.events()
        XCTAssertEqual(events, unchanged)
    }

    @MainActor
    func test_fallbackTTSStopPropagatesCancellationAndLateOldStartCannotAffectB() async throws {
        let fixture = VoiceLatencyFixture()
        let started = expectation(description: "fallback requested")
        let driver = VoiceFallbackDriver(onSpeak: { started.fulfill() })
        let tts = TTSService(kokoroEngine: nil, fallbackFactory: { driver })
        let playback = AudioPlaybackService(driver: VoicePlaybackDriver())
        let context = fixture.context()
        let task = Task { try await playback.play(chunks: tts.speak("Test", latencyContext: context), latencyContext: context) }
        await fulfillment(of: [started], timeout: 2)
        let lateStart = driver.startCallback
        await tts.stop()
        do { try await task.value; XCTFail("fallback stop succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        let b = fixture.context()
        lateStart?()
        fixture.observer.complete(.error, for: b.attempt, reason: "test_error")
        let events = await fixture.events()
        XCTAssertEqual(events.filter { $0.name == .voiceLatencyBoundaryObserved }.count, 0)
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled", "error"])
    }
}

@MainActor
final class LegacyVoiceControllerTests: XCTestCase {
    func test_controllerUsesSourceContextAndOrdinaryMultiChunkCompletion() async throws {
        let fixture = VoiceLatencyFixture()
        let scheduled = expectation(description: "scheduled")
        scheduled.expectedFulfillmentCount = 2
        let driver = VoicePlaybackDriver(onSchedule: { scheduled.fulfill() })
        let controller = makeController(fixture, playback: AudioPlaybackService(driver: driver), tts: VoicePCMService())
        controller.currentVoiceLatencyTurn = fixture.observer.beginTurn()
        controller.state = .responding
        controller.speakResponse("Test")
        let task = try XCTUnwrap(controller.ttsTask)
        await fulfillment(of: [scheduled], timeout: 2)
        driver.complete(0)
        driver.complete(1)
        await task.value
        XCTAssertEqual(controller.state, .awaitingFollowUp)
        XCTAssertNil(controller.currentVoiceLatencyAttempt)
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["success"])
    }

    func test_interruptClosesAttemptAndTextModeResetsTurn() async throws {
        let fixture = VoiceLatencyFixture()
        let scheduled = expectation(description: "scheduled")
        scheduled.expectedFulfillmentCount = 2
        let driver = VoicePlaybackDriver(onSchedule: { scheduled.fulfill() })
        let controller = makeController(fixture, playback: AudioPlaybackService(driver: driver), tts: VoicePCMService())
        controller.currentVoiceLatencyTurn = fixture.observer.beginTurn()
        controller.state = .responding
        controller.speakResponse("A")
        let a = try XCTUnwrap(controller.currentVoiceLatencyAttempt)
        let task = try XCTUnwrap(controller.ttsTask)
        await fulfillment(of: [scheduled], timeout: 2)
        controller.interruptSpeech()
        await task.value
        XCTAssertEqual(controller.state, .awaitingFollowUp)
        fixture.observer.playbackBoundary(for: a, backend: .kokoro, boundary: .scheduled)
        controller.switchToTextInput()
        XCTAssertNil(controller.currentVoiceLatencyTurn)
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled"])
        XCTAssertEqual(string(try XCTUnwrap(events.last), "reason"), "interrupted")
        controller.cancel()
    }

    func test_repeatedSpeechACompletionCannotTransitionBOrStopItsPlayback() async throws {
        let fixture = VoiceLatencyFixture()
        let aScheduled = expectation(description: "A scheduled")
        aScheduled.expectedFulfillmentCount = 2
        let bScheduled = expectation(description: "B scheduled")
        bScheduled.expectedFulfillmentCount = 2
        let driver = VoicePlaybackDriver(onSchedule: { count in
            (count <= 2 ? aScheduled : bScheduled).fulfill()
        })
        let playback = AudioPlaybackService(driver: driver)
        let controller = makeController(fixture, playback: playback, tts: VoicePCMService())
        controller.currentVoiceLatencyTurn = fixture.observer.beginTurn()
        controller.state = .responding
        controller.speakResponse("A")
        let a = try XCTUnwrap(controller.currentVoiceLatencyAttempt)
        let aTask = try XCTUnwrap(controller.ttsTask)
        await fulfillment(of: [aScheduled], timeout: 2)
        controller.speakResponse("B")
        let b = try XCTUnwrap(controller.currentVoiceLatencyAttempt)
        let bTask = try XCTUnwrap(controller.ttsTask)
        await fulfillment(of: [bScheduled], timeout: 2)
        await aTask.value
        await playback.stop(latencyAttempt: a) // A delayed stop is fenced too.
        driver.complete(0)
        driver.complete(1)
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(controller.currentVoiceLatencyAttempt, b)
        let playing = await playback.playing
        XCTAssertTrue(playing)
        driver.complete(2)
        driver.complete(3)
        await bTask.value
        XCTAssertEqual(controller.state, .awaitingFollowUp)
        XCTAssertEqual(a.voiceTurnID, b.voiceTurnID)
        XCTAssertNotEqual(a.speechAttemptID, b.speechAttemptID)
        let events = await fixture.events()
        XCTAssertEqual(terminals(events).map { string($0, "outcome") }, ["cancelled", "success"])
    }

    func test_textModeSkipsSpeechWithoutAttempt() async {
        let fixture = VoiceLatencyFixture()
        let controller = makeController(fixture, playback: AudioPlaybackService(driver: VoicePlaybackDriver()), tts: VoicePCMService())
        controller.inputMode = .text
        controller.state = .responding
        controller.speakResponse("Test")
        XCTAssertEqual(controller.state, .awaitingFollowUp)
        XCTAssertNil(controller.ttsTask)
        let events = await fixture.events()
        XCTAssertTrue(events.isEmpty)
    }

    func test_ASRReceiptUsesCapturedTurnAndSubmitKeepsSeparateTimestamp() async throws {
        let fixture = VoiceLatencyFixture()
        let scheduled = expectation(description: "scheduled")
        scheduled.expectedFulfillmentCount = 2
        let driver = VoicePlaybackDriver(onSchedule: { scheduled.fulfill() })
        let controller = makeController(fixture, playback: AudioPlaybackService(driver: driver), tts: VoicePCMService())
        let old = fixture.observer.beginTurn()
        controller.currentVoiceLatencyTurn = old
        let current = fixture.observer.beginTurn()
        controller.currentVoiceLatencyTurn = current
        controller.state = .listening
        controller.receiveASREvent(.final(text: "stale"), for: old)
        XCTAssertEqual(controller.currentTranscript, "")
        fixture.clock.set(110)
        controller.receiveASREvent(.final(text: "Test"), for: current)
        fixture.clock.set(140)
        controller.submitTranscript()
        fixture.clock.set(200)
        controller.state = .responding // Agent response accepted before TTS.
        controller.speakResponse("Test")
        let task = try XCTUnwrap(controller.ttsTask)
        await fulfillment(of: [scheduled], timeout: 2)
        fixture.clock.set(400)
        driver.complete(0)
        driver.complete(1)
        await task.value
        let events = await fixture.events()
        let terminal = try XCTUnwrap(events.last)
        XCTAssertEqual(integer(terminal, "asrFinalToPlaybackBoundaryMilliseconds"), 90)
        XCTAssertEqual(integer(terminal, "acceptedTranscriptToPlaybackBoundaryMilliseconds"), 60)
        XCTAssertEqual(integer(terminal, "ttsRequestToCompletionMilliseconds"), 200)
    }

    private func makeController(_ fixture: VoiceLatencyFixture, playback: AudioPlaybackService,
                                tts: any TTSServicing) -> SimplePipelineController {
        SimplePipelineController.makeTestInstance(overlayPresenter: MockOverlayPresenter(),
            audioService: MockAudioService(), ttsService: tts, playbackService: playback,
            legacyVoiceLatencyObserver: fixture.observer,
            persistenceService: MockPersistenceService(conversationModeEnabled: false))
    }
}

private final class VoiceClock: LegacyVoiceLatencyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 100
    func set(_ value: UInt64) { self.lock.withLock { self.value = value } }
    func now() -> UInt64 { self.lock.withLock { self.value } }
}

private struct VoiceLatencyFixture {
    let clock = VoiceClock()
    let sink = InMemoryTelemetrySink()
    let observer: LegacyVoiceLatencyObserver
    init() { self.observer = LegacyVoiceLatencyObserver(clock: self.clock, sink: self.sink) }
    func context() -> LegacyVoiceLatencyContext {
        let turn = self.observer.beginTurn()
        return LegacyVoiceLatencyContext(attempt: self.observer.beginAttempt(for: turn), observer: self.observer)
    }
    func events() async -> [TelemetryEvent] {
        await self.observer.flush()
        return await self.sink.snapshot()
    }
}

private final class VoicePlaybackDriver: AudioPlaybackDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []
    private let onSchedule: @Sendable (Int) -> Void
    init(onSchedule: @escaping @Sendable (Int) -> Void = { _ in }) { self.onSchedule = onSchedule }
    convenience init(onSchedule: @escaping @Sendable () -> Void) { self.init(onSchedule: { _ in onSchedule() }) }
    var count: Int { self.lock.withLock { self.callbacks.count } }
    func start() {}
    func stop() {} // Keep callbacks to deliberately deliver stale events.
    func schedule(_ chunk: AudioChunk, completion: @escaping @Sendable () -> Void) {
        let count = self.lock.withLock {
            self.callbacks.append(completion)
            return self.callbacks.count
        }
        self.onSchedule(count)
    }
    func complete(_ index: Int) { self.lock.withLock { self.callbacks[index] }() }
}

@MainActor
private final class VoiceFallbackDriver: FallbackSpeechDriving {
    var startCallback: (@Sendable () -> Void)?
    var finishCallback: (@Sendable (FallbackSpeechResult) -> Void)?
    var immediateCompletion: FallbackSpeechResult?
    private(set) var speakCount = 0
    private let onSpeak: () -> Void
    init(onSpeak: @escaping () -> Void = {}) { self.onSpeak = onSpeak }
    func speak(text: String, onStart: @escaping @Sendable () -> Void,
               onCompletion: @escaping @Sendable (FallbackSpeechResult) -> Void) {
        self.speakCount += 1
        self.startCallback = onStart
        self.finishCallback = onCompletion
        self.onSpeak()
        if let immediateCompletion { onCompletion(immediateCompletion) }
    }
    func stop() { self.finishCallback?(.cancelled) }
}

private actor VoiceKokoroEngine: KokoroEngining {
    func synthesize(text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield([])
            continuation.yield([0.1])
            continuation.yield([0.2])
            continuation.finish()
        }
    }
}

private struct VoicePCMService: TTSServicing {
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> { chunks([pcm(), pcm()]) }
    func speak(_ text: String, latencyContext: LegacyVoiceLatencyContext?) -> AsyncThrowingStream<AudioChunk, Error> {
        if let latencyContext { latencyContext.observer.firstPCMChunkReceived(for: latencyContext.attempt) }
        return self.speak(text)
    }
    func stop() async {}
}

private func pcm() -> AudioChunk { AudioChunk(samples: [0.1], sampleRate: 24000) }
private func chunks(_ chunks: [AudioChunk]) -> AsyncThrowingStream<AudioChunk, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}
private func terminals(_ events: [TelemetryEvent]) -> [TelemetryEvent] {
    events.filter { $0.name == .voiceLatencyAttemptCompleted }
}
private func integer(_ event: TelemetryEvent, _ key: String) -> Int? {
    guard case .integer(let value)? = event.fields.first(where: { $0.key == key })?.value else { return nil }
    return value
}
private func string(_ event: TelemetryEvent, _ key: String) -> String? {
    guard case .string(let value)? = event.fields.first(where: { $0.key == key })?.value else { return nil }
    return value
}
