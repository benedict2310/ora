import XCTest
@testable import Ora

@MainActor
final class PipelineTTSInjectionTests: XCTestCase {
    func test_makeTestInstance_usesInjectedTTSService() {
        let tts = MockTTSService()
        let controller = SimplePipelineController.makeTestInstance(ttsService: tts)

        XCTAssertTrue(controller.ttsService is MockTTSService)
    }
}
