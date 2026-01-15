//
//  OverlayLayoutTests.swift
//  OraTests
//
//  Tests for overlay layout spacing constants
//

import XCTest
@testable import Ora

final class OverlayLayoutTests: XCTestCase {
    // MARK: - Container Spacing Tests

    func test_containerSpacing_isDefined() {
        XCTAssertGreaterThan(OverlayLayout.containerSpacing, 0, "Container spacing must be greater than 0")
    }

    func test_containerSpacing_isLessThanRowSpacing() {
        // Critical constraint: container spacing must be less than row spacing
        // to prevent glass shapes from blending at rest (per Apple's Liquid Glass guidance)
        XCTAssertLessThan(
            OverlayLayout.containerSpacing,
            OverlayLayout.rowSpacing,
            "Container spacing must be less than row spacing to prevent glass blending"
        )
    }

    // MARK: - Row Spacing Tests

    func test_rowSpacing_isDefined() {
        XCTAssertGreaterThan(OverlayLayout.rowSpacing, 0, "Row spacing must be greater than 0")
    }

    // MARK: - Bubble Padding Tests

    func test_bubblePaddingHorizontal_isDefined() {
        XCTAssertGreaterThan(OverlayLayout.bubblePaddingHorizontal, 0, "Horizontal padding must be greater than 0")
    }

    func test_bubblePaddingVertical_isDefined() {
        XCTAssertGreaterThan(OverlayLayout.bubblePaddingVertical, 0, "Vertical padding must be greater than 0")
    }

    // MARK: - Content Spacing Tests

    func test_bubbleContentSpacing_isDefined() {
        XCTAssertGreaterThan(OverlayLayout.bubbleContentSpacing, 0, "Bubble content spacing must be greater than 0")
    }

    func test_toolContentSpacing_isDefined() {
        XCTAssertGreaterThan(OverlayLayout.toolContentSpacing, 0, "Tool content spacing must be greater than 0")
    }

    // MARK: - Spacing Relationships Tests

    func test_spacingValues_areReasonable() {
        // Verify spacing values are in reasonable ranges for UI
        XCTAssertLessThanOrEqual(OverlayLayout.containerSpacing, 20, "Container spacing should be reasonable")
        XCTAssertLessThanOrEqual(OverlayLayout.rowSpacing, 20, "Row spacing should be reasonable")
        XCTAssertLessThanOrEqual(OverlayLayout.bubblePaddingHorizontal, 30, "Horizontal padding should be reasonable")
        XCTAssertLessThanOrEqual(OverlayLayout.bubblePaddingVertical, 30, "Vertical padding should be reasonable")
        XCTAssertLessThanOrEqual(OverlayLayout.bubbleContentSpacing, 15, "Bubble content spacing should be reasonable")
        XCTAssertLessThanOrEqual(OverlayLayout.toolContentSpacing, 15, "Tool content spacing should be reasonable")
    }

    func test_containerSpacing_exactValue() {
        // Verify the exact value to catch unintentional changes
        XCTAssertEqual(OverlayLayout.containerSpacing, 4, "Container spacing should be 4")
    }

    func test_rowSpacing_exactValue() {
        // Verify the exact value to catch unintentional changes
        XCTAssertEqual(OverlayLayout.rowSpacing, 20, "Row spacing should be 20")
    }
}
