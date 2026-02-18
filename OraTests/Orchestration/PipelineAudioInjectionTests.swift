import XCTest
@testable import Ora

@MainActor
final class PipelineAudioInjectionTests: XCTestCase {
    func test_makeTestInstance_usesInjectedAudioService() {
        let audio = MockAudioService()
        let controller = SimplePipelineController.makeTestInstance(audioService: audio)

        XCTAssertTrue(controller.audioService is MockAudioService)
    }
}
