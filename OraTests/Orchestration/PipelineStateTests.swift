//
//  PipelineStateTests.swift
//  OraTests
//
//  Tests for PipelineState enum
//

import XCTest
@testable import Ora

final class PipelineStateTests: XCTestCase {
    
    // MARK: - Description Tests
    
    func test_idle_description() {
        let state = PipelineState.idle
        XCTAssertEqual(state.description, "Ready")
    }
    
    func test_listening_description() {
        let state = PipelineState.listening
        XCTAssertEqual(state.description, "Listening...")
    }
    
    func test_thinking_description() {
        let state = PipelineState.thinking
        XCTAssertEqual(state.description, "Thinking...")
    }
    
    func test_responding_description() {
        let state = PipelineState.responding
        XCTAssertEqual(state.description, "Responding...")
    }
    
    func test_awaitingFollowUp_description() {
        let state = PipelineState.awaitingFollowUp
        XCTAssertEqual(state.description, "Awaiting Follow-up")
    }
    
    func test_completed_description() {
        let state = PipelineState.completed
        XCTAssertEqual(state.description, "Done")
    }
    
    func test_error_description() {
        let state = PipelineState.error("Something went wrong")
        XCTAssertEqual(state.description, "Error: Something went wrong")
    }
    
    // MARK: - canStartListening Tests
    
    func test_canStartListening_fromIdle_isTrue() {
        XCTAssertTrue(PipelineState.idle.canStartListening)
    }
    
    func test_canStartListening_fromCompleted_isTrue() {
        XCTAssertTrue(PipelineState.completed.canStartListening)
    }
    
    func test_canStartListening_fromAwaitingFollowUp_isTrue() {
        XCTAssertTrue(PipelineState.awaitingFollowUp.canStartListening)
    }
    
    func test_canStartListening_fromError_isTrue() {
        XCTAssertTrue(PipelineState.error("test").canStartListening)
    }
    
    func test_canStartListening_fromListening_isFalse() {
        XCTAssertFalse(PipelineState.listening.canStartListening)
    }
    
    func test_canStartListening_fromThinking_isFalse() {
        XCTAssertFalse(PipelineState.thinking.canStartListening)
    }
    
    func test_canStartListening_fromResponding_isFalse() {
        XCTAssertFalse(PipelineState.responding.canStartListening)
    }
    
    // MARK: - Equatable Tests
    
    func test_equatable_sameStates_areEqual() {
        XCTAssertEqual(PipelineState.idle, PipelineState.idle)
        XCTAssertEqual(PipelineState.listening, PipelineState.listening)
        XCTAssertEqual(PipelineState.thinking, PipelineState.thinking)
        XCTAssertEqual(PipelineState.responding, PipelineState.responding)
        XCTAssertEqual(PipelineState.completed, PipelineState.completed)
        XCTAssertEqual(PipelineState.error("test"), PipelineState.error("test"))
    }
    
    func test_equatable_differentStates_areNotEqual() {
        XCTAssertNotEqual(PipelineState.idle, PipelineState.listening)
        XCTAssertNotEqual(PipelineState.thinking, PipelineState.responding)
        XCTAssertNotEqual(PipelineState.error("a"), PipelineState.error("b"))
    }
    
    // MARK: - Sendable Conformance
    
    func test_sendable_canBeSentAcrossTasks() async {
        let state = PipelineState.thinking
        
        // This compiles only if PipelineState is Sendable
        let result = await Task.detached { () -> PipelineState in
            return state
        }.value
        
        XCTAssertEqual(result, .thinking)
    }
}
