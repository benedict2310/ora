import XCTest
@testable import Ora

final class ScreenshotCaptureServiceTests: XCTestCase {

    func test_captureScreenshotPNG_whenPermissionDenied_throwsPermissionDenied() async {
        let service = ScreenshotCaptureService(
            accessController: MockScreenCaptureAccessController(
                preflightResult: false,
                requestResult: false
            )
        )

        do {
            _ = try await service.captureScreenshotPNG()
            XCTFail("Expected permissionDenied error")
        } catch let error as ScreenshotCaptureError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct MockScreenCaptureAccessController: ScreenCaptureAccessControlling {
    let preflightResult: Bool
    let requestResult: Bool

    func preflightAccess() -> Bool {
        self.preflightResult
    }

    func requestAccess() -> Bool {
        self.requestResult
    }
}
