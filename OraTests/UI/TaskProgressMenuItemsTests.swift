//
//  TaskProgressMenuItemsTests.swift
//  OraTests
//
//  Tests for task progress menu section rendering.
//

import AppKit
import XCTest
@testable import Ora

final class TaskProgressMenuItemsTests: XCTestCase {

    func test_menuItems_hiddenWhenNoActiveTasks() {
        let items = TaskProgressMenuItems.makeSection(
            tasks: [],
            target: nil,
            cancelAction: #selector(NSObject.description)
        )

        XCTAssertTrue(items.isEmpty)
    }

    func test_menuItems_showCancelButton() {
        let task = TaskProgressItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            label: "Research: example.com",
            detail: "https://example.com",
            phase: .fetching(urlCount: 2),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let items = TaskProgressMenuItems.makeSection(
            tasks: [task],
            target: nil,
            cancelAction: #selector(NSObject.description)
        )

        XCTAssertEqual(items.map(\.title), [
            "Background Tasks",
            "Research: example.com - Fetching 2 URLs",
            "Cancel Research: example.com"
        ])
        XCTAssertEqual((items[2].representedObject as? NSUUID) as UUID?, task.id)
    }
}
