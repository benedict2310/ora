import XCTest
@testable import OraCore

final class AssistantOperationLifecycleTests: XCTestCase {
    func test_hostOutcomeMatrixSeparatesOperationFactsFromOrdinaryPresentation() async throws {
        for actionName in ["calendar.query", "system.open_app", "system.open_url", "reminders.create"] {
            for observation in LifecycleObservation.allCases {
                for invalidation in LifecycleInvalidation.allCases {
                    for boundary in LifecycleBoundary.allCases {
                        try await self.checkHostOutcome(actionName: actionName, observation: observation, invalidation: invalidation, boundary: boundary)
                    }
                }
            }
        }
    }

    private func checkHostOutcome(actionName: String, observation: LifecycleObservation, invalidation: LifecycleInvalidation, boundary: LifecycleBoundary) async throws {
        let firstID = TelemetryTurnID("lifecycle-first")
        let latestID = TelemetryTurnID("lifecycle-latest")
        let action = try XCTUnwrap(ActionCatalog.v2Default.action(named: actionName))
        let gate = LifecycleGate(boundary: boundary)
        let sink = LifecycleSink(turnID: firstID, observation: observation, gate: gate)
        let host = LifecycleHost(observation: observation, gate: gate)
        let store = InMemoryAuditStore()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 10_000, step: 10), sinks: [sink])
        let session = AssistantSession(generator: LifecycleGenerator(output: .action(name: actionName)), actionHost: host, auditStore: store, telemetryRecorder: recorder)
        let submit = Task {
            let outcome = await session.submitText(AssistantTextRequest(turnID: firstID, text: "Private original request."))
            await gate.finished()
            return outcome
        }
        let reachedBoundary = await gate.wait()
        // Completion is a deterministic counterexample when an expected boundary is missing,
        // not a timeout or a substitute for successful lifecycle observation.
        XCTAssertTrue(reachedBoundary, "Missing boundary: \(actionName), \(observation), \(boundary)")
        if invalidation.cancels { submit.cancel() }
        var latestProposal: ActionProposal?
        if invalidation.replaces {
            let latestOutcome = await session.submitText(AssistantTextRequest(turnID: latestID, text: "Private latest request."))
            let pending = await session.pendingProposal()
            let proposal = try XCTUnwrap(pending)
            latestProposal = proposal
            XCTAssertEqual(latestOutcome, .proposal(AssistantTurnProposal(turnID: latestID, proposal: proposal, message: proposal.summary)))
        }
        await gate.release()
        let outcome = await submit.value
        let events = await sink.snapshot()
        let firstEvents = events.filter { $0.turnID == firstID }
        let operations = firstEvents.filter { Self.actionTerminals.contains($0.name) }
        let turns = firstEvents.filter { Self.turnTerminals.contains($0.name) }
        let pending = await session.pendingProposal()
        let effects = await host.effectCount()
        let calls = await host.firstCallCount()
        let entries = await store.entries()
        let detail = "\(actionName), \(observation), \(invalidation), \(boundary)"
        XCTAssertEqual(calls, 1, detail)
        XCTAssertEqual(effects, observation.reportsExecution ? 1 : 0, detail)
        XCTAssertTrue(entries.isEmpty, detail)
        XCTAssertEqual(operations.map(\.name), [observation.terminal], detail)
        if let terminal = operations.first {
            Self.assertPublicField(terminal, "actionName", .string(action.name))
            Self.assertPublicField(terminal, "actionDomain", .string(action.domain.rawValue))
            Self.assertPublicField(terminal, "actionKind", .string(action.kind.rawValue))
            if observation.reportsExecution && action.kind == .mutation {
                Self.assertPublicField(terminal, "resultCategory", .string("mutation_executed_without_approval"))
            }
        }
        if invalidation != .current {
            guard case .cancelled = outcome else { return XCTFail("Abandoned UI escaped: \(detail)") }
            XCTAssertEqual(pending, latestProposal, detail)
            // Proposed turns are open until publication/approval/rejection. Their turn boundary
            // is proposal publication, not a nonexistent committed turn terminal.
            let committed = boundary == .turnPresentation && observation != .proposed
            let expectedTurn = committed ? observation.turnTerminal(for: action) : .turnCancelled
            XCTAssertEqual(turns.map(\.name), [expectedTurn], detail)
        } else {
            switch observation {
            case .executed where action.kind == .read:
                XCTAssertEqual(outcome, .result(AssistantTurnResult(turnID: firstID, message: "Private host summary.")))
            case .proposed:
                let proposal = try XCTUnwrap(pending)
                XCTAssertEqual(outcome, .proposal(AssistantTurnProposal(turnID: firstID, proposal: proposal, message: proposal.summary)))
            case .cancelled:
                guard case .cancelled = outcome else { return XCTFail("Cooperative cancellation became failure") }
            default:
                guard case .failure = outcome else { return XCTFail("Current failure was hidden: \(detail)") }
            }
            XCTAssertEqual(turns.map(\.name), observation == .proposed ? [] : [observation.turnTerminal(for: action)], detail)
        }
        Self.assertPrivacy(events)
        Self.assertSpanBalance(firstEvents, openTurn: invalidation == .current && observation == .proposed)
        XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
        if let pending { _ = try await session.reject(proposal: pending) }
        let finalOpen = await recorder.openSpanCount()
        XCTAssertEqual(finalOpen, 0, detail)
    }

    func test_modelTurnTerminalMatrixFencesTaskCancellationWithoutRelabellingCommittedTerminal() async throws {
        for failure in LifecycleModelOutcome.allCases {
            for invalidation in LifecycleInvalidation.allCases {
                let firstID = TelemetryTurnID("model-first")
                let gate = LifecycleGate(boundary: .turnPresentation)
                let sink = LifecycleSink(turnID: firstID, observation: nil, gate: gate)
                let host = LifecycleHost(observation: .proposed, gate: gate)
                let store = InMemoryAuditStore()
                let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 20_000, step: 10), sinks: [sink])
                let session = AssistantSession(generator: LifecycleModelGenerator(outcome: failure, firstID: firstID), actionHost: host, auditStore: store, telemetryRecorder: recorder)
                let submit = Task {
                    let outcome = await session.submitText(AssistantTextRequest(turnID: firstID, text: "Private original request."))
                    await gate.finished()
                    return outcome
                }
                let reached = await gate.wait()
                XCTAssertTrue(reached)
                if invalidation.cancels { submit.cancel() }
                if invalidation.replaces { _ = await session.submitText(AssistantTextRequest(turnID: TelemetryTurnID("model-latest"), text: "Private latest request.")) }
                let expectedPending = await session.pendingProposal()
                await gate.release()
                let outcome = await submit.value
                let events = await sink.snapshot()
                let firstEvents = events.filter { $0.turnID == firstID }
                XCTAssertEqual(firstEvents.map(\.name), [.turnStarted, .inputTextReceived, failure.terminal])
                if invalidation != .current {
                    guard case .cancelled = outcome else { return XCTFail("Committed model terminal escaped cancellation: \(failure), \(invalidation)") }
                } else if failure == .response {
                    XCTAssertEqual(outcome, .result(AssistantTurnResult(turnID: firstID, message: "Private host summary.")))
                } else if failure == .cancelled {
                    guard case .cancelled = outcome else { return XCTFail("Model cancellation should stay cancelled") }
                } else {
                    guard case .failure = outcome else { return XCTFail("Genuine model error must fail") }
                }
                let pending = await session.pendingProposal()
                XCTAssertEqual(pending, expectedPending)
                Self.assertSpanBalance(firstEvents, openTurn: false)
                Self.assertPrivacy(events)
                let entries = await store.entries()
                XCTAssertTrue(entries.isEmpty)
                if let pending { _ = try await session.reject(proposal: pending) }
                let openSpans = await recorder.openSpanCount()
                XCTAssertEqual(openSpans, 0)
            }
        }
    }

    func test_invalidationBeforeHostInvocationSkipsEffectsAndCancelsOpenAttempt() async throws {
        for invalidation in [LifecycleInvalidation.replaced, .cancelled, .both] {
            let firstID = TelemetryTurnID("before-host")
            let gate = LifecycleGate(boundary: .actionTerminal)
            let sink = LifecycleSink(turnID: firstID, observation: .executed, gate: gate, gateStart: true)
            let host = LifecycleHost(observation: .executed, gate: gate, expectedActionName: "system.open_app")
            let store = InMemoryAuditStore()
            let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 30_000, step: 10), sinks: [sink])
            let session = AssistantSession(generator: LifecycleGenerator(output: .action(name: "system.open_app")), actionHost: host, auditStore: store, telemetryRecorder: recorder)
            let submit = Task {
                let outcome = await session.submitText(AssistantTextRequest(turnID: firstID, text: "Private original request."))
                await gate.finished()
                return outcome
            }
            let reached = await gate.wait()
            XCTAssertTrue(reached)
            if invalidation.cancels { submit.cancel() }
            if invalidation.replaces { _ = await session.submitText(AssistantTextRequest(turnID: TelemetryTurnID("before-host-latest"), text: "Private latest request.")) }
            await gate.release()
            let outcome = await submit.value
            guard case .cancelled = outcome else { return XCTFail("Pre-host invalidation must cancel") }
            let effects = await host.effectCount()
            let calls = await host.firstCallCount()
            XCTAssertEqual(effects, 0)
            XCTAssertEqual(calls, 0)
            let events = await sink.snapshot()
            let firstEvents = events.filter { $0.turnID == firstID }
            XCTAssertEqual(firstEvents.map(\.name), [.turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionCancelled, .turnCancelled])
            Self.assertSpanBalance(firstEvents, openTurn: false)
            let pending = await session.pendingProposal()
            if let pending { _ = try await session.reject(proposal: pending) }
            let openSpans = await recorder.openSpanCount()
            XCTAssertEqual(openSpans, 0)
        }
    }

    func test_cooperativeCancellationDoesNotAssertRollbackOfAnAlreadyObservedFakeEffect() async throws {
        let gate = LifecycleGate(boundary: .handler)
        let host = LifecycleHost(observation: .cancelled, gate: gate, partialEffect: true)
        let sink = LifecycleSink(turnID: TelemetryTurnID("partial"), observation: .cancelled, gate: gate)
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 40_000, step: 10), sinks: [sink])
        let session = AssistantSession(generator: LifecycleGenerator(output: .action(name: "system.open_url")), actionHost: host, auditStore: InMemoryAuditStore(), telemetryRecorder: recorder)
        let submit = Task { await session.submitText(AssistantTextRequest(turnID: TelemetryTurnID("partial"), text: "Private original request.")) }
        let reached = await gate.wait()
        XCTAssertTrue(reached)
        submit.cancel()
        await gate.release()
        let outcome = await submit.value
        guard case .cancelled = outcome else { return XCTFail("Cancellation signal must stay cancellation") }
        let effects = await host.effectCount()
        let events = await sink.snapshot()
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(events.filter { Self.actionTerminals.contains($0.name) }.map(\.name), [.actionExecutionCancelled])
        Self.assertSpanBalance(events, openTurn: false)
    }

    private static let actionTerminals: Set<TelemetryEventName> = [.actionExecutionCompleted, .actionExecutionFailed, .actionExecutionCancelled]
    private static let turnTerminals: Set<TelemetryEventName> = [.turnCompleted, .turnFailed, .turnCancelled]

    private static func assertSpanBalance(_ events: [TelemetryEvent], openTurn: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for start in events where start.name == .turnStarted || start.name == .actionExecutionStarted {
            let id = start.fields.first { $0.key == "spanID" }?.value
            let terminals = events.filter { (Self.actionTerminals.contains($0.name) || Self.turnTerminals.contains($0.name)) && $0.fields.first { $0.key == "spanID" }?.value == id }
            XCTAssertEqual(terminals.count, start.name == .turnStarted && openTurn ? 0 : 1, file: file, line: line)
        }
    }

    private static func assertPublicField(_ event: TelemetryEvent, _ key: String, _ value: TelemetryFieldValue, file: StaticString = #filePath, line: UInt = #line) {
        let field = event.fields.first { $0.key == key }
        XCTAssertEqual(field?.value, value, file: file, line: line)
        XCTAssertEqual(field?.visibility, .publicDebug, file: file, line: line)
    }

    private static func assertPrivacy(_ events: [TelemetryEvent], file: StaticString = #filePath, line: UInt = #line) {
        for event in events {
            let rendered = OSTelemetrySink.render(event).message
            for secret in ["Private original request.", "Private latest request.", "Private host summary.", "Private unexpected action.", "Private host error."] {
                XCTAssertFalse(rendered.contains(secret), file: file, line: line)
            }
        }
    }
}

private enum LifecycleObservation: CaseIterable, Sendable {
    case executed, proposed, error, cancelled, mismatchedExecution, mismatchedProposal
    var reportsExecution: Bool { self == .executed || self == .mismatchedExecution }
    var terminal: TelemetryEventName {
        switch self {
        case .executed: return .actionExecutionCompleted
        case .proposed, .cancelled: return .actionExecutionCancelled
        default: return .actionExecutionFailed
        }
    }
    func turnTerminal(for action: Action) -> TelemetryEventName {
        if self == .cancelled { return .turnCancelled }
        return self == .executed && action.kind == .read ? .turnCompleted : .turnFailed
    }
}

private enum LifecycleInvalidation: CaseIterable {
    case current, replaced, cancelled, both
    var replaces: Bool { self == .replaced || self == .both }
    var cancels: Bool { self == .cancelled || self == .both }
}

private enum LifecycleBoundary: CaseIterable, Sendable { case handler, actionTerminal, turnPresentation }

private actor LifecycleGate {
    private let boundary: LifecycleBoundary
    private var reached = false
    private var done = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var blocker: CheckedContinuation<Void, Never>?
    init(boundary: LifecycleBoundary) { self.boundary = boundary }
    func pause(_ boundary: LifecycleBoundary) async {
        guard boundary == self.boundary, !self.reached else { return }
        self.reached = true
        self.waiter?.resume(returning: true)
        self.waiter = nil
        await withCheckedContinuation { self.blocker = $0 }
    }
    func finished() {
        self.done = true
        self.waiter?.resume(returning: self.reached)
        self.waiter = nil
    }
    func wait() async -> Bool {
        if self.reached { return true }
        if self.done { return false }
        return await withCheckedContinuation { self.waiter = $0 }
    }
    func release() { self.blocker?.resume(); self.blocker = nil }
}

private actor LifecycleSink: TelemetrySink {
    private let turnID: TelemetryTurnID
    private let observation: LifecycleObservation?
    private let gate: LifecycleGate
    private let gateStart: Bool
    private var events: [TelemetryEvent] = []
    init(turnID: TelemetryTurnID, observation: LifecycleObservation?, gate: LifecycleGate, gateStart: Bool = false) {
        self.turnID = turnID; self.observation = observation; self.gate = gate; self.gateStart = gateStart
    }
    func record(_ event: TelemetryEvent) async {
        self.events.append(event)
        guard event.turnID == self.turnID else { return }
        if self.gateStart {
            if event.name == .actionExecutionStarted { await self.gate.pause(.actionTerminal) }
            return
        }
        if [.actionExecutionCompleted, .actionExecutionFailed, .actionExecutionCancelled].contains(event.name) {
            await self.gate.pause(.actionTerminal)
        }
        if [.turnCompleted, .turnFailed, .turnCancelled].contains(event.name) || (self.observation == .proposed && event.name == .actionProposalCreated) {
            await self.gate.pause(.turnPresentation)
        }
    }
    func snapshot() -> [TelemetryEvent] { self.events }
}

private enum LifecycleError: LocalizedError, Sendable {
    case failure
    var errorDescription: String? { "Private host error." }
}

private actor LifecycleHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default
    private let observation: LifecycleObservation
    private let gate: LifecycleGate
    private let partialEffect: Bool
    private let expectedActionName: String?
    private var calls = 0
    private var effects = 0
    init(observation: LifecycleObservation, gate: LifecycleGate, partialEffect: Bool = false, expectedActionName: String? = nil) {
        self.observation = observation; self.gate = gate; self.partialEffect = partialEffect; self.expectedActionName = expectedActionName
    }
    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else { throw ActionHostError.unsupportedAction(name) }
        if let expectedActionName = self.expectedActionName, name != expectedActionName { return .proposed(ActionProposal(action: action)) }
        self.calls += 1
        if self.calls > 1 { return .proposed(ActionProposal(action: action)) }
        if self.observation.reportsExecution || self.partialEffect { self.effects += 1 }
        await self.gate.pause(.handler)
        let wrong = Action(name: "Private unexpected action.", domain: action.domain, kind: action.kind)
        switch self.observation {
        case .executed: return .executed(action: action, summary: "Private host summary.")
        case .proposed: return .proposed(ActionProposal(action: action))
        case .mismatchedExecution: return .executed(action: wrong, summary: "Private host summary.")
        case .mismatchedProposal: return .proposed(ActionProposal(action: wrong))
        case .error: throw LifecycleError.failure
        case .cancelled: try Task.checkCancellation(); throw CancellationError()
        }
    }
    func firstCallCount() -> Int { min(self.calls, 1) }
    func effectCount() -> Int { self.effects }
}

private actor LifecycleGenerator: StructuredOutputGenerating {
    private let output: StructuredAssistantOutput
    private var calls = 0
    init(output: StructuredAssistantOutput) { self.output = output }
    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        self.calls += 1
        return self.calls == 1 ? self.output : .action(name: "reminders.create")
    }
}

private enum LifecycleModelOutcome: CaseIterable, Sendable {
    case response, validation, error, unsupported, cancelled
    var terminal: TelemetryEventName { self == .response ? .turnCompleted : (self == .cancelled ? .turnCancelled : .turnFailed) }
}

private actor LifecycleModelGenerator: StructuredOutputGenerating {
    private let outcome: LifecycleModelOutcome
    private let firstID: TelemetryTurnID
    init(outcome: LifecycleModelOutcome, firstID: TelemetryTurnID) { self.outcome = outcome; self.firstID = firstID }
    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        guard request.turnID == self.firstID else { return .action(name: "reminders.create") }
        switch self.outcome {
        case .response: return .response(message: "Private host summary.")
        case .unsupported: return .action(name: "Private unexpected action.")
        case .validation: throw StructuredOutputGenerationError.validationFailed
        case .error: throw LifecycleError.failure
        case .cancelled: throw CancellationError()
        }
    }
}
