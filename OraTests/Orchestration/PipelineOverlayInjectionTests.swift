import XCTest
@testable import Ora

@MainActor
final class PipelineOverlayInjectionTests: XCTestCase {
    func test_makeTestInstance_usesInjectedOverlayPresenter() {
        let overlay = MockOverlayPresenter()
        let controller = SimplePipelineController.makeTestInstance(overlayPresenter: overlay)

        XCTAssertTrue(controller.overlayPresenter is MockOverlayPresenter)
    }
}
