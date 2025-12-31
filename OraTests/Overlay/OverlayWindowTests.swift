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
}
