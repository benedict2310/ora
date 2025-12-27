//
//  StatusBarControllerTests.swift
//  OraTests
//
//  Unit tests for StatusBarController
//

import XCTest
@testable import Ora

@MainActor
final class StatusBarControllerTests: XCTestCase {

    // TC-1: Initial state is idle
    func test_initialState_isIdle() {
        let controller = StatusBarController()
        XCTAssertEqual(controller.state, .idle)
    }

    // TC-2: State can be changed
    func test_setState_updatesState() {
        let controller = StatusBarController()
        controller.setState(.listening)
        XCTAssertEqual(controller.state, .listening)
    }

    // TC-3: Same state is ignored (no redundant updates)
    func test_setState_sameState_noChange() {
        let controller = StatusBarController()
        controller.setState(.idle)
        // Should not crash or cause issues
        XCTAssertEqual(controller.state, .idle)
    }

    // TC-4: Error state carries message
    func test_errorState_hasMessage() {
        let controller = StatusBarController()
        controller.setState(.error("Test error"))
        if case .error(let message) = controller.state {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Expected error state")
        }
    }

    // TC-5: All states are reachable
    func test_allStates_areReachable() {
        let controller = StatusBarController()

        controller.setState(.idle)
        XCTAssertEqual(controller.state, .idle)

        controller.setState(.listening)
        XCTAssertEqual(controller.state, .listening)

        controller.setState(.thinking)
        XCTAssertEqual(controller.state, .thinking)

        controller.setState(.speaking)
        XCTAssertEqual(controller.state, .speaking)

        controller.setState(.error("Error message"))
        if case .error = controller.state {
            // Pass
        } else {
            XCTFail("Expected error state")
        }

        controller.setState(.setupRequired)
        XCTAssertEqual(controller.state, .setupRequired)
    }

    // TC-6: State enum equality works correctly
    func test_stateEquality() {
        XCTAssertEqual(StatusBarController.State.idle, StatusBarController.State.idle)
        XCTAssertEqual(StatusBarController.State.listening, StatusBarController.State.listening)
        XCTAssertNotEqual(StatusBarController.State.idle, StatusBarController.State.listening)

        // Error states with same message are equal
        XCTAssertEqual(
            StatusBarController.State.error("same"),
            StatusBarController.State.error("same")
        )

        // Error states with different messages are not equal
        XCTAssertNotEqual(
            StatusBarController.State.error("one"),
            StatusBarController.State.error("two")
        )
    }
}
