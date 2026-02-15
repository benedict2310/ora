//
//  MemoryPreferencesViewTests.swift
//  OraTests
//
//  Tests for Memory Preferences view rendering and actions.
//

import XCTest
import SwiftUI
@testable import Ora

final class MemoryPreferencesViewTests: XCTestCase {

    func test_memoryPreferencesView_rendersWithoutCrash() throws {
        let view = MemoryPreferencesView()
        let hostingController = NSHostingController(rootView: view)
        XCTAssertNotNil(hostingController.view)
    }

    func test_preferencesTab_includesMemory() {
        let tabs = PreferencesTab.allCases
        XCTAssertTrue(tabs.contains(.memory))
    }

    func test_memoryTab_hasCorrectTitleAndIcon() {
        XCTAssertEqual(PreferencesTab.memory.title, "Memory")
        XCTAssertEqual(PreferencesTab.memory.icon, "brain")
    }

    func test_memoryTab_isBetweenModelsAndPermissions() {
        let tabs = PreferencesTab.allCases
        guard let memoryIndex = tabs.firstIndex(of: .memory),
              let modelsIndex = tabs.firstIndex(of: .models),
              let permissionsIndex = tabs.firstIndex(of: .permissions) else {
            XCTFail("Expected memory, models, and permissions tabs to exist")
            return
        }

        XCTAssertGreaterThan(memoryIndex, modelsIndex, "Memory tab should come after Models")
        XCTAssertLessThan(memoryIndex, permissionsIndex, "Memory tab should come before Permissions")
    }
}
