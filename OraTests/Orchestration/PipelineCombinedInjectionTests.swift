import XCTest
@testable import Ora

@MainActor
final class PipelineCombinedInjectionTests: XCTestCase {
    func test_makeTestInstance_acceptsAllInjectedDependencies() {
        let overlay = MockOverlayPresenter()
        let audio = MockAudioService()
        let tts = MockTTSService()
        let persistence = MockPersistenceService(conversationModeEnabled: true, silenceTimeout: 1.4)

        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            audioService: audio,
            ttsService: tts,
            persistenceService: persistence
        )

        XCTAssertTrue(controller.overlayPresenter is MockOverlayPresenter)
        XCTAssertTrue(controller.audioService is MockAudioService)
        XCTAssertTrue(controller.ttsService is MockTTSService)
        XCTAssertEqual(controller.persistenceService.settings.silenceTimeout, 1.4, accuracy: 0.001)
    }
}
