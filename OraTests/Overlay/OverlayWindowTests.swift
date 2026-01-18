//
//  OverlayWindowTests.swift
//  OraTests
//
//  Tests for overlay window visibility and key status
//

import XCTest
@testable import Ora

@MainActor
final class OverlayWindowTests: XCTestCase {
    
    func test_overlayWindow_canBecomeKey() {
        // Given
        let controller = OverlayWindowController.shared
        
        // When
        controller.show()
        
        // Then
        // We can't access 'panel' directly as it's private, but we can verify behavior via side effects
        // or using Mirror if absolutely necessary, but better to trust the integration.
        // However, for this reproduction, we need to assert that the underlying window claims it can be key.
        
        // Let's use Mirror to inspect the private panel property
        let mirror = Mirror(reflecting: controller)
        guard let panel = mirror.children.first(where: { $0.label == "panel" })?.value as? NSPanel else {
            XCTFail("Could not access panel via reflection")
            return
        }
        
        XCTAssertTrue(panel.canBecomeKey, "Overlay panel must override canBecomeKey to return true")
        XCTAssertEqual(panel.styleMask.contains(.borderless), true, "Style mask must contain .borderless")
        XCTAssertEqual(panel.styleMask.contains(.nonactivatingPanel), false, "Style mask must NOT contain .nonactivatingPanel")
        XCTAssertEqual(panel.becomesKeyOnlyIfNeeded, false, "becomesKeyOnlyIfNeeded must be false")
    }

    func test_rapidHideAndShow_keepsWindowVisible() async {
        // Given
        let controller = OverlayWindowController.shared
        
        // Initial show
        controller.show()
        
        // Hide (animated) - this schedules a completion handler
        controller.hide(animated: true)
        
        // Show immediately - this should invalidate the hide completion's effect
        controller.show()
        
        // Wait enough time for the hide animation (0.15s) to "complete" and the Task to run
        try? await Task.sleep(for: .seconds(0.3))
        
        // Then
        let mirror = Mirror(reflecting: controller)
        guard let panel = mirror.children.first(where: { $0.label == "panel" })?.value as? NSPanel else {
            XCTFail("Could not access panel via reflection")
            return
        }
        
        XCTAssertTrue(panel.isVisible, "Panel should be visible")
        XCTAssertEqual(panel.alphaValue, 1.0, accuracy: 0.01, "Panel alpha should be 1.0")
        
        // Cleanup
        controller.hide(animated: false)
    }

    func test_overlayWindow_sizeMatchesDesign() {
        let controller = OverlayWindowController.shared

        controller.show()

        guard let panel = self.extractPanel() else {
            XCTFail("Could not access panel via reflection")
            return
        }

        XCTAssertEqual(panel.frame.size.width, OverlayLayout.panelWidth, accuracy: 0.5)
        XCTAssertEqual(panel.frame.size.height, OverlayLayout.panelHeight, accuracy: 0.5)

        controller.hide(animated: false)
    }

    func test_overlayWindow_positionsTopCenter() {
        let controller = OverlayWindowController.shared

        controller.show()

        guard let panel = self.extractPanel() else {
            XCTFail("Could not access panel via reflection")
            return
        }

        guard let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            XCTFail("Unable to read screen frame")
            return
        }

        let expectedX = screenFrame.midX - panel.frame.width / 2
        let expectedY = screenFrame.maxY - panel.frame.height - OverlayLayout.topMargin

        XCTAssertEqual(panel.frame.origin.x, expectedX, accuracy: 1.0)
        // Allow for animation offset (panel may be mid-animation when checked)
        XCTAssertEqual(panel.frame.origin.y, expectedY, accuracy: OverlayLayout.showHideSlideDistance + 2)

        controller.hide(animated: false)
    }

    func test_appDeactivation_cancelsWhenNoPromptActive() async {
        let controller = OverlayWindowController.shared
        let originalCancelHandler = controller.cancelHandler
        let expectation = XCTestExpectation(description: "Cancel handler called")

        controller.show()
        controller.cancelHandler = {
            expectation.fulfill()
        }

        PermissionPromptTracker.shared.endPrompt(for: .microphone)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        await fulfillment(of: [expectation], timeout: 1.0)

        controller.cancelHandler = originalCancelHandler
        controller.hide(animated: false)
    }

    private func extractPanel() -> NSPanel? {
        let mirror = Mirror(reflecting: OverlayWindowController.shared)
        return mirror.children.first(where: { $0.label == "panel" })?.value as? NSPanel
    }
}
