import XCTest
@testable import OraCore

final class AssistantStateTests: XCTestCase {
    func test_happyPathTransitions_areDeterministic() throws {
        let idle = AssistantState.idle
        let listening = try idle.transition(on: .startListening)
        let thinking = try listening.transition(on: .submitTranscript)
        let responding = try thinking.transition(on: .startResponding)
        let awaitingFollowUp = try responding.transition(on: .finishResponse)

        XCTAssertEqual(listening, .listening)
        XCTAssertEqual(thinking, .thinking)
        XCTAssertEqual(responding, .responding)
        XCTAssertEqual(awaitingFollowUp, .awaitingFollowUp)
    }

    func test_idleAndListeningCanTransitionToError() throws {
        XCTAssertEqual(try AssistantState.idle.transition(on: .fail("idle failed")), .error("idle failed"))
        XCTAssertEqual(try AssistantState.listening.transition(on: .fail("listening failed")), .error("listening failed"))
    }

    func test_listeningCancelReturnsIdle() throws {
        XCTAssertEqual(try AssistantState.listening.transition(on: .cancel), .idle)
    }

    func test_invalidTransitionsThrow() {
        XCTAssertThrowsError(try AssistantState.idle.transition(on: .submitTranscript)) { error in
            XCTAssertEqual(
                error as? AssistantStateTransitionError,
                .invalidTransition(from: .idle, event: .submitTranscript)
            )
        }
    }
}
