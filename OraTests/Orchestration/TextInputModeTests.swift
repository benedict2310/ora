import XCTest
@testable import Ora

@MainActor
final class TextInputModeTests: XCTestCase {

    func test_switchToTextInput_fromListening_switchesModeAndSeedsFirstCharacter() async throws {
        let overlay = MockOverlayPresenter()
        let audio = MockAudioService()
        let asr = MockASRService()
        let controller = SimplePipelineController.makeTestInstance(
            asrService: asr,
            overlayPresenter: overlay,
            audioService: audio,
            persistenceService: MockPersistenceService(conversationModeEnabled: false)
        )

        controller.transition(to: .listening)
        overlay.mode = .listening

        controller.switchToTextInput(initialText: "h")
        try await Task.sleep(for: .milliseconds(40))
        let stopCalls = await audio.stopCalls()
        let resetCalls = asr.resetCalls()

        XCTAssertEqual(controller.inputMode, .text)
        XCTAssertEqual(overlay.model.inputMode, .text)
        XCTAssertTrue(overlay.model.isTextInputVisible)
        XCTAssertEqual(overlay.model.textInputText, "h")
        XCTAssertEqual(stopCalls, 1)
        XCTAssertEqual(resetCalls, 1)
    }

    func test_submitTextInput_processesTypedMessageWithAttachments() async throws {
        let overlay = MockOverlayPresenter()
        let store = MockAttachmentStore()
        let screenshotService = MockScreenshotCaptureService()
        let capture = CapturedInput()
        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            ttsService: MockTTSService(),
            persistenceService: MockPersistenceService(conversationModeEnabled: false),
            attachmentStore: store,
            screenshotCaptureService: screenshotService,
            providerPreflight: { .ready },
            prepareLLM: {},
            agentProcessor: { text, imageAttachments in
                await capture.record(text: text, attachments: imageAttachments)
                return .response(text: "Done")
            }
        )

        controller.transition(to: .listening)
        controller.inputMode = .text
        overlay.model.inputMode = .text
        overlay.model.isTextInputVisible = true

        let attachment = Self.sampleAttachment(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        controller.setPendingImageAttachmentsForTesting([attachment])
        controller.submitTextInput("Review this image")
        try await Task.sleep(for: .milliseconds(120))

        let capturedText = await capture.text
        let capturedAttachments = await capture.attachments
        XCTAssertEqual(capturedText, "Review this image")
        XCTAssertEqual(capturedAttachments.count, 1)
        XCTAssertEqual(capturedAttachments.first?.attachmentID, attachment.id)
        XCTAssertEqual(overlay.model.textInputText, "")
        XCTAssertFalse(overlay.model.isTextInputVisible)
    }

    func test_startFollowUp_inTextMode_doesNotRestartAudioCapture() async throws {
        let overlay = MockOverlayPresenter()
        let audio = MockAudioService()
        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            audioService: audio,
            ttsService: MockTTSService(),
            persistenceService: MockPersistenceService(conversationModeEnabled: false)
        )

        controller.transition(to: .listening)
        controller.transition(to: .thinking)
        controller.transition(to: .awaitingFollowUp)
        controller.inputMode = .text
        overlay.model.inputMode = .text

        controller.startFollowUp()
        try await Task.sleep(for: .milliseconds(40))
        let startCalls = await audio.startCalls()

        XCTAssertEqual(controller.state, .awaitingFollowUp)
        XCTAssertEqual(startCalls, 0)
    }

    func test_reEnableVoiceInput_fromTextMode_startsListeningImmediately() async throws {
        let overlay = MockOverlayPresenter()
        let audio = MockAudioService()
        let asr = MockASRService()
        let controller = SimplePipelineController.makeTestInstance(
            asrService: asr,
            overlayPresenter: overlay,
            audioService: audio,
            ttsService: MockTTSService(),
            persistenceService: MockPersistenceService(conversationModeEnabled: false)
        )

        controller.transition(to: .listening)
        controller.inputMode = .text
        overlay.model.inputMode = .text
        overlay.model.isTextInputVisible = true

        controller.reEnableVoiceInput()
        try await Task.sleep(for: .milliseconds(40))
        let startCalls = await audio.startCalls()

        XCTAssertEqual(controller.inputMode, .voice)
        XCTAssertEqual(overlay.model.inputMode, .voice)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(startCalls, 1)
    }

    func test_inputMode_resetsToVoice_onCancelAndNewSessionStart() async throws {
        let overlay = MockOverlayPresenter()
        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            ttsService: MockTTSService(),
            persistenceService: MockPersistenceService(conversationModeEnabled: false)
        )

        controller.transition(to: .listening)
        controller.inputMode = .text
        overlay.model.inputMode = .text

        controller.cancel()
        XCTAssertEqual(controller.inputMode, .voice)
        XCTAssertEqual(overlay.model.inputMode, .voice)

        controller.inputMode = .text
        overlay.model.inputMode = .text
        controller.startListening()

        XCTAssertEqual(controller.inputMode, .voice)
        XCTAssertEqual(overlay.model.inputMode, .voice)
    }

    func test_typingHintTimer_setsHintAndCancelsOnVoiceOrTyping() async throws {
        let overlay = MockOverlayPresenter()
        let audio = MockAudioService()
        let asr = MockASRService()
        let controller = SimplePipelineController.makeTestInstance(
            asrService: asr,
            overlayPresenter: overlay,
            audioService: audio,
            persistenceService: MockPersistenceService(conversationModeEnabled: false),
            typingHintDelay: 0.05
        )

        controller.transition(to: .listening)
        controller.inputMode = .voice
        overlay.model.inputMode = .voice

        controller.startTypingHintTimer()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(overlay.model.typingHintVisible)

        controller.cancelTypingHintForVoiceActivity()
        XCTAssertFalse(overlay.model.typingHintVisible)

        controller.startTypingHintTimer()
        controller.switchToTextInput(initialText: "x")
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertFalse(overlay.model.typingHintVisible)
        XCTAssertEqual(controller.inputMode, .text)
    }

    private static func sampleAttachment(id: UUID) -> StagedImageAttachment {
        return StagedImageAttachment(
            id: id,
            source: .clipboard,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalFilename: nil,
            stagedFilePath: "/tmp/\(id.uuidString).png",
            thumbnailFilePath: nil,
            mimeType: "image/png",
            byteCount: 4096,
            pixelWidth: 1024,
            pixelHeight: 768
        )
    }
}

private actor CapturedInput {
    private(set) var text: String?
    private(set) var attachments: [LLMImageAttachmentReference] = []

    func record(text: String, attachments: [LLMImageAttachmentReference]) {
        self.text = text
        self.attachments = attachments
    }
}
