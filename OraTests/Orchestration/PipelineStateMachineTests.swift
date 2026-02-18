import XCTest
@testable import Ora

final class PipelineStateMachineTests: XCTestCase {

    private let stateMachine = PipelineStateMachine()

    func test_canTransition_allowsCoreHappyPathTransitions() {
        XCTAssertTrue(self.stateMachine.canTransition(from: .idle, to: .listening))
        XCTAssertTrue(self.stateMachine.canTransition(from: .listening, to: .thinking))
        XCTAssertTrue(self.stateMachine.canTransition(from: .thinking, to: .responding))
        XCTAssertTrue(self.stateMachine.canTransition(from: .responding, to: .speaking))
        XCTAssertTrue(self.stateMachine.canTransition(from: .speaking, to: .awaitingFollowUp))
        XCTAssertTrue(self.stateMachine.canTransition(from: .awaitingFollowUp, to: .listening))
    }

    func test_canTransition_allowsRecoveryTransitions() {
        XCTAssertTrue(self.stateMachine.canTransition(from: .thinking, to: .error("x")))
        XCTAssertTrue(self.stateMachine.canTransition(from: .error("x"), to: .idle))
        XCTAssertTrue(self.stateMachine.canTransition(from: .error("x"), to: .awaitingFollowUp))
    }

    func test_canTransition_rejectsInvalidTransitions() {
        XCTAssertFalse(self.stateMachine.canTransition(from: .idle, to: .speaking))
        XCTAssertFalse(self.stateMachine.canTransition(from: .listening, to: .speaking))
        XCTAssertFalse(self.stateMachine.canTransition(from: .completed, to: .listening))
    }
}
