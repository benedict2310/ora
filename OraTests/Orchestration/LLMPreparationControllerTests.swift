import XCTest
@testable import Ora

@MainActor
final class LLMPreparationControllerTests: XCTestCase {
    func test_preparationOverlapsASRAndCancellationDoesNotCancelForegroundJoin() async throws {
        let loader = PreparationTestLoader()
        let joined = expectation(description: "Foreground joins early load")
        let local = LLMService(modelLoader: { try await loader.load($0) }, preparationObserver: {
            if $0.phase == .joined { joined.fulfill() }
        })
        let manager = manager(local)
        let asrStarted = expectation(description: "ASR runs while model loader is suspended")
        let asr = PreparationASR { asrStarted.fulfill() }
        let earlyFinished = PreparationTestSignal()
        let controller = controller(asr: asr, early: {
            await manager.prepareLocalIfEligible()
            await earlyFinished.signal()
        })
        controller.startListening()
        await loader.started.wait()
        await fulfillment(of: [asrStarted], timeout: 2)
        XCTAssertEqual(controller.state, .listening)
        let foreground = Task { try await manager.prepare() }
        await fulfillment(of: [joined], timeout: 2)
        controller.cancel()
        await loader.release.signal()
        try await foreground.value
        await earlyFinished.wait()
        XCTAssertEqual(controller.state, .idle)
        let loads = await loader.count
        XCTAssertEqual(loads, 1)
    }

    func test_cloudListeningRunsASRWithoutStartingLocalPreparation() async {
        let loader = PreparationTestLoader(suspendFirst: false)
        let local = LLMService(modelLoader: { try await loader.load($0) })
        let manager = LLMProviderManager(credentialStore: MockCredentialStore(), codexOAuthManager: MockCodexOAuthManager(),
            localProvider: local, selectedProviderType: .anthropic, persistSelection: { _ in XCTFail("Unexpected preference write") })
        let asrStarted = expectation(description: "Cloud voice still runs ASR")
        let earlyFinished = PreparationTestSignal()
        let controller = controller(asr: PreparationASR { asrStarted.fulfill() }, early: {
            await manager.prepareLocalIfEligible()
            await earlyFinished.signal()
        })
        controller.startListening()
        await earlyFinished.wait()
        await fulfillment(of: [asrStarted], timeout: 2)
        let count = await loader.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(controller.state, .listening)
        controller.cancel()
    }

    func test_cancelBeforeTaskLaunchSuppressesObsoletePreparation() async {
        let called = expectation(description: "No obsolete early preparation")
        called.isInverted = true
        let controller = controller(early: { called.fulfill() })
        controller.startListening()
        controller.cancel()
        await fulfillment(of: [called], timeout: 0.2)
        XCTAssertEqual(controller.state, .idle)
    }

    func test_textSwitchBeforeTaskLaunchSuppressesObsoletePreparation() async {
        let called = expectation(description: "No early preparation after switching to text")
        called.isInverted = true
        let controller = controller(early: { called.fulfill() })
        controller.startListening()
        controller.switchToTextInput()
        await fulfillment(of: [called], timeout: 0.2)
        XCTAssertEqual(controller.inputMode, .text)
        controller.cancel()
    }

    func test_followUpAndBothVoiceReenablePathsStartPreparation() async {
        for entry in 0..<3 {
            let called = expectation(description: "Accepted voice entry \(entry)")
            let controller = controller(early: { called.fulfill() })
            controller.transition(to: .listening)
            if entry != 1 {
                controller.transition(to: .thinking)
                controller.transition(to: .awaitingFollowUp)
            }
            if entry == 0 {
                controller.startFollowUp()
            } else {
                controller.inputMode = .text
                controller.reEnableVoiceInput()
            }
            await fulfillment(of: [called], timeout: 2)
            XCTAssertEqual(controller.state, .listening)
            controller.cancel()
        }
    }

    func test_textFollowUpAndTextSubmissionDoNotStartEarlyWork() async {
        let called = expectation(description: "Text does not prepare early")
        called.isInverted = true
        let processed = expectation(description: "Authoritative text path still works")
        let controller = controller(early: { called.fulfill() }, process: {
            processed.fulfill()
            return .response(text: "Done")
        })
        controller.transition(to: .listening)
        controller.transition(to: .thinking)
        controller.transition(to: .awaitingFollowUp)
        controller.inputMode = .text
        controller.startFollowUp()
        XCTAssertEqual(controller.state, .awaitingFollowUp)
        controller.transition(to: .listening)
        controller.submitTextInput("Hello")
        await fulfillment(of: [processed, called], timeout: 0.2)
        XCTAssertEqual(controller.currentResponse, "Done")
        controller.cancel()
    }

    func test_earlyFailureDoesNotAbortASRAndForegroundRetryProducesNormalResult() async {
        let loader = PreparationTestLoader(suspendFirst: false, failFirst: true)
        let local = LLMService(modelLoader: { try await loader.load($0) })
        let manager = manager(local)
        let earlyFinished = PreparationTestSignal()
        let asrStarted = expectation(description: "ASR stays independent of early error")
        let processed = expectation(description: "Normal agent result after foreground retry")
        let asr = PreparationASR { asrStarted.fulfill() }
        let controller = controller(asr: asr, early: {
            await manager.prepareLocalIfEligible()
            await earlyFinished.signal()
        }, foreground: { try await manager.prepare() }, process: {
            processed.fulfill()
            return .response(text: "Done")
        })
        controller.startListening()
        await earlyFinished.wait()
        await fulfillment(of: [asrStarted], timeout: 2)
        XCTAssertEqual(controller.state, .listening)
        asr.finish(text: "Hello")
        await fulfillment(of: [processed], timeout: 2)
        await controller.sessionTask?.value
        XCTAssertEqual(controller.currentResponse, "Done")
        let loads = await loader.count
        XCTAssertEqual(loads, 2)
        controller.cancel()
    }

    func test_foregroundFailureRemainsAuthoritative() async {
        let controller = controller(early: {}, foreground: { throw LLMServiceError.modelNotFound })
        controller.transition(to: .listening)
        controller.currentTranscript = "Hello"
        await controller.processTranscript()
        guard case .error = controller.state else { return XCTFail("Foreground preparation failure must surface") }
        controller.cancel()
    }

    func test_ASRFailureDoesNotReceiveLatePreparationUIUpdates() async {
        let loader = PreparationTestLoader()
        let local = LLMService(modelLoader: { try await loader.load($0) })
        let manager = manager(local)
        let asrStarted = expectation(description: "ASR starts")
        let asr = PreparationASR { asrStarted.fulfill() }
        let earlyFinished = PreparationTestSignal()
        let controller = controller(asr: asr, early: {
            await manager.prepareLocalIfEligible()
            await earlyFinished.signal()
        })
        controller.startListening()
        await loader.started.wait()
        await fulfillment(of: [asrStarted], timeout: 2)
        let session = controller.sessionTask
        asr.fail()
        await session?.value
        guard case .error = controller.state else { return XCTFail("ASR failure must surface independently") }
        let state = controller.state
        await loader.release.signal()
        await earlyFinished.wait()
        XCTAssertEqual(controller.state, state)
        controller.cancel()
    }

    private func manager(_ local: LLMService) -> LLMProviderManager {
        LLMProviderManager(credentialStore: MockCredentialStore(), codexOAuthManager: MockCodexOAuthManager(),
                           localProvider: local, selectedProviderType: .local, persistSelection: { _ in XCTFail("Unexpected preference write") })
    }

    private func controller(
        asr: PreparationASR = PreparationASR(),
        early: @escaping @Sendable () async -> Void,
        foreground: @escaping @Sendable () async throws -> Void = {},
        process: @escaping @Sendable () async throws -> AgentResult = { .response(text: "Done") }
    ) -> SimplePipelineController {
        SimplePipelineController.makeTestInstance(asrService: asr, overlayPresenter: MockOverlayPresenter(),
            audioService: MockAudioService(), ttsService: MockTTSService(),
            playbackService: AudioPlaybackService(engine: nil, playerNode: nil, simulateOutput: true),
            persistenceService: MockPersistenceService(conversationModeEnabled: false),
            attachmentStore: MockAttachmentStore(), screenshotCaptureService: MockScreenshotCaptureService(),
            providerPreflight: { .ready }, prepareLLM: foreground, prepareLocalLLM: early,
            agentProcessor: { _, _ in try await process() })
    }
}

private final class PreparationASR: ASRServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ASREvent, Error>.Continuation?
    private let onStart: @Sendable () -> Void
    init(onStart: @escaping @Sendable () -> Void = {}) { self.onStart = onStart }
    func reset() async {}
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock { self.continuation = continuation }
            self.onStart()
        }
    }
    func transcribe(frames: AsyncStream<AudioFrame>, onVADStateChange: @escaping @Sendable @MainActor (Bool) -> Void) -> AsyncThrowingStream<ASREvent, Error> {
        self.transcribe(frames: frames)
    }
    func finish(text: String) {
        let continuation = self.lock.withLock { self.continuation }
        continuation?.yield(.final(text: text))
        continuation?.finish()
    }
    func fail() { self.lock.withLock { self.continuation }?.finish(throwing: LLMServiceError.modelNotFound) }
}
