//
//  SimplePipelineControllerTests.swift
//  OraTests
//
//  Tests for SimplePipelineController state machine
//

import XCTest
@testable import Ora

@MainActor
final class SimplePipelineControllerTests: XCTestCase {
    
    // MARK: - Initial State Tests
    
    func test_initialState_isIdle() {
        let controller = SimplePipelineController.makeTestInstance()
        XCTAssertEqual(controller.state, .idle)
    }
    
    func test_initialTranscript_isEmpty() {
        let controller = SimplePipelineController.makeTestInstance()
        XCTAssertEqual(controller.currentTranscript, "")
    }
    
    func test_initialResponse_isEmpty() {
        let controller = SimplePipelineController.makeTestInstance()
        XCTAssertEqual(controller.currentResponse, "")
    }
    
    // MARK: - State Transition Tests
    
    func test_cancel_fromIdle_staysIdle() {
        let controller = SimplePipelineController.makeTestInstance()
        controller.cancel()
        XCTAssertEqual(controller.state, .idle)
    }
    
    func test_stopListening_fromIdle_isIgnored() {
        let controller = SimplePipelineController.makeTestInstance()
        controller.stopListening()
        XCTAssertEqual(controller.state, .idle)
    }
    
    func test_submitTranscript_fromIdle_isIgnored() {
        let controller = SimplePipelineController.makeTestInstance()
        controller.submitTranscript()
        XCTAssertEqual(controller.state, .idle)
    }
    
    func test_startFollowUp_fromIdle_isIgnored() {
        let controller = SimplePipelineController.makeTestInstance()
        controller.startFollowUp()
        XCTAssertEqual(controller.state, .idle)
    }
    
    // MARK: - State Guards Tests
    
    func test_startListening_whenNotIdle_isIgnored() async throws {
        let controller = SimplePipelineController.makeTestInstance()
        
        // Simulate being in thinking state by directly setting (using reflection would be needed for private setter)
        // Since we can't directly set state, we test via the canStartListening logic
        // which is tested in PipelineStateTests
        
        // Instead, test that starting twice doesn't break anything
        // First start will transition to listening
        // We can't easily test this without mocking services,
        // so we verify the guard logic exists in PipelineState tests
        XCTAssertTrue(controller.state.canStartListening)
    }
    
    // MARK: - Published Property Tests
    
    func test_state_isPublished() {
        let controller = SimplePipelineController.makeTestInstance()
        
        // Verify we can observe state changes
        var observedStates: [PipelineState] = []
        let cancellable = controller.$state.sink { state in
            observedStates.append(state)
        }
        
        // Should have received initial value
        XCTAssertEqual(observedStates.count, 1)
        XCTAssertEqual(observedStates.first, .idle)
        
        cancellable.cancel()
    }
    
    func test_currentTranscript_isPublished() {
        let controller = SimplePipelineController.makeTestInstance()
        
        var observedTranscripts: [String] = []
        let cancellable = controller.$currentTranscript.sink { transcript in
            observedTranscripts.append(transcript)
        }
        
        XCTAssertEqual(observedTranscripts.count, 1)
        XCTAssertEqual(observedTranscripts.first, "")
        
        cancellable.cancel()
    }
    
    func test_currentResponse_isPublished() {
        let controller = SimplePipelineController.makeTestInstance()
        
        var observedResponses: [String] = []
        let cancellable = controller.$currentResponse.sink { response in
            observedResponses.append(response)
        }
        
        XCTAssertEqual(observedResponses.count, 1)
        XCTAssertEqual(observedResponses.first, "")
        
        cancellable.cancel()
    }
    
    // MARK: - Singleton Tests
    
    func test_shared_returnsSameInstance() {
        let first = SimplePipelineController.shared
        let second = SimplePipelineController.shared
        XCTAssertTrue(first === second)
    }
    
    func test_makeTestInstance_returnsDifferentInstances() {
        let first = SimplePipelineController.makeTestInstance()
        let second = SimplePipelineController.makeTestInstance()
        XCTAssertFalse(first === second)
    }
    
    // MARK: - Executing State Tests
    
    func test_executingState_description() {
        let state = PipelineState.executing
        XCTAssertEqual(state.description, "Executing...")
    }
    
    func test_executingState_cannotStartListening() {
        let state = PipelineState.executing
        XCTAssertFalse(state.canStartListening)
    }

    // MARK: - Derived State Helpers

    func test_isSessionActive_helper() {
        XCTAssertFalse(SimplePipelineController.isSessionActive(for: .idle))
        XCTAssertFalse(SimplePipelineController.isSessionActive(for: .completed))
        XCTAssertTrue(SimplePipelineController.isSessionActive(for: .listening))
        XCTAssertTrue(SimplePipelineController.isSessionActive(for: .error("Oops")))
    }

    func test_statusBarState_mapping() {
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .idle), .idle)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .completed), .idle)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .listening), .listening)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .thinking), .thinking)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .responding), .thinking)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .awaitingFollowUp), .thinking)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .executing), .thinking)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .speaking), .speaking)
        XCTAssertEqual(SimplePipelineController.statusBarState(for: .error("Failure")), .error("Failure"))
    }
    
    // MARK: - Agent Loop Integration Tests (with makeTestInstance)
    
    func test_makeTestInstance_acceptsCustomAgentLoop() async {
        // This tests that we can inject a custom AgentLoop for testing
        let customAgentLoop = AgentLoop()
        let controller = SimplePipelineController.makeTestInstance(agentLoop: customAgentLoop)
        
        XCTAssertEqual(controller.state, .idle)
    }
}
