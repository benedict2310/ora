import XCTest
@testable import OraCore

final class AssistantSessionTests: XCTestCase {
    func test_submitText_readOnlyActionReturnsResultWithDeterministicTelemetry() async throws {
        let turnID = TelemetryTurnID("turn-read")
        let request = AssistantTextRequest(turnID: turnID, text: "What is on my calendar today?")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "calendar.query"))
        let host = FakeActionHost()
        let auditStore = InMemoryAuditStore()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 1_000, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )

        let outcome = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let approvedExecutionCount = await host.approvedExecutionCount()
        let readExecutionCount = await host.readExecutionCount()
        let invocationCount = await host.invocationCount()
        let auditEntries = await auditStore.entries()
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .result(AssistantTurnResult(turnID: turnID, message: "Found 3 events for today."))
        )
        XCTAssertNil(pendingProposal)
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionExecutionStarted,
                .actionExecutionCompleted,
                .turnCompleted
            ]
        )
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEqual(approvedExecutionCount, 0)
        XCTAssertEqual(readExecutionCount, 1)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(auditEntries.isEmpty)

        XCTAssertEventField(events[0], key: "phase", equals: .string("turn"))
        XCTAssertEventField(events[0], key: "state", equals: .string("started"))
        XCTAssertEventField(events[0], key: "source", equals: .string("text"))

        XCTAssertEventField(events[1], key: "phase", equals: .string("input"))
        XCTAssertEventField(events[1], key: "state", equals: .string("received"))
        XCTAssertEventField(events[1], key: "source", equals: .string("text"))
        XCTAssertEventField(events[1], key: "characterCount", equals: .integer(request.text.count))

        XCTAssertEventField(events[2], key: "actionName", equals: .string("calendar.query"))
        XCTAssertEventField(events[2], key: "actionDomain", equals: .string("calendar"))
        XCTAssertEventField(events[2], key: "actionKind", equals: .string("read"))

        XCTAssertEventField(events[3], key: "resultCategory", equals: .string("executed"))
        XCTAssertEventField(events[3], key: "durationMilliseconds", equals: .integer(10))
        XCTAssertEventField(events[4], key: "resultCategory", equals: .string("executed"))
        XCTAssertEventField(events[4], key: "durationMilliseconds", equals: .integer(40))
    }

    func test_submitText_responseReturnsResultAndClosesTurnNormally() async throws {
        let turnID = TelemetryTurnID("turn-response-control")
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 1_500, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: FakeStructuredOutputGenerator(output: .response(message: "Private response.")),
            actionHost: FakeActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )
        let outcome = await session.submitText(AssistantTextRequest(turnID: turnID, text: "Private request."))
        let events = await sink.snapshot()
        let openSpanCount = await recorder.openSpanCount()
        XCTAssertEqual(outcome, .result(AssistantTurnResult(turnID: turnID, message: "Private response.")))
        XCTAssertEventNames(events, [.turnStarted, .inputTextReceived, .turnCompleted])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertEventField(events[2], key: "resultCategory", equals: .string("response"))
        XCTAssertEqual(openSpanCount, 0)
        XCTAssertNoVisibleRequestContent("Private request.", in: events)
        XCTAssertNoVisibleRequestContent("Private response.", in: events)
    }

    func test_responseReplacedDuringTurnCompletionDoesNotReturnStaleResultOrDuplicateTerminal() async throws {
        try await self.assertResultReplacedDuringTerminalTelemetry(
            output: .response(message: "Private response."),
            gatedEvent: .turnCompleted,
            expectedFirstEvents: [.turnStarted, .inputTextReceived, .turnCompleted]
        )
    }

    func test_readResultReplacedDuringTurnCompletionDoesNotReturnStaleResultOrDuplicateTerminal() async throws {
        try await self.assertResultReplacedDuringTerminalTelemetry(
            output: .action(name: "calendar.query"),
            gatedEvent: .turnCompleted,
            expectedFirstEvents: [
                .turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionCompleted, .turnCompleted
            ]
        )
    }

    func test_readResultReplacedDuringActionCompletionCancelsOnlyOpenTurnSpan() async throws {
        try await self.assertResultReplacedDuringTerminalTelemetry(
            output: .action(name: "calendar.query"),
            gatedEvent: .actionExecutionCompleted,
            expectedFirstEvents: [
                .turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionCompleted, .turnCancelled
            ]
        )
    }

    private func assertResultReplacedDuringTerminalTelemetry(
        output: StructuredAssistantOutput,
        gatedEvent: TelemetryEventName,
        expectedFirstEvents: [TelemetryEventName]
    ) async throws {
        let firstTurnID = TelemetryTurnID("turn-terminal-first")
        let secondTurnID = TelemetryTurnID("turn-terminal-second")
        let sink = GatedFirstTerminalTelemetrySink(gatedEvent: gatedEvent)
        let host = FakeActionHost()
        let auditStore = InMemoryAuditStore()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 1_600, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: SequencedStructuredOutputGenerator(outputs: [output, .action(name: "reminders.create")]),
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )
        let firstSubmit = Task {
            await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Private first request."))
        }
        await sink.waitForFirstTerminal()
        let secondOutcome = await session.submitText(
            AssistantTextRequest(turnID: secondTurnID, text: "Private replacement request.")
        )
        let pending = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(pending)
        await sink.releaseFirstTerminal()

        let firstOutcome = await firstSubmit.value
        let finalPending = await session.pendingProposal()
        let events = await sink.snapshot()
        let openSpanCount = await recorder.openSpanCount()
        let approvedExecutionCount = await host.approvedExecutionCount()
        let auditEntries = await auditStore.entries()
        XCTAssertEqual(
            firstOutcome,
            .cancelled(AssistantTurnCancellation(turnID: firstTurnID, message: "Okay, I moved on to the latest request."))
        )
        XCTAssertEqual(
            secondOutcome,
            .proposal(AssistantTurnProposal(turnID: secondTurnID, proposal: secondProposal, message: secondProposal.summary))
        )
        XCTAssertEqual(finalPending, secondProposal)
        XCTAssertNotNil(secondProposal.proposalID)
        XCTAssertEventNames(events.filter { $0.turnID == firstTurnID }, expectedFirstEvents)
        XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
        XCTAssertEqual(openSpanCount, 1)
        XCTAssertEqual(approvedExecutionCount, 0)
        XCTAssertTrue(auditEntries.isEmpty)
        XCTAssertNoVisibleRequestContent("Private first request.", in: events)
        XCTAssertNoVisibleRequestContent("Private replacement request.", in: events)
        XCTAssertNoVisibleRequestContent("Private response.", in: events)
        XCTAssertNoVisibleRequestContent("Found 3 events for today.", in: events)

        _ = try await session.reject(proposal: secondProposal)
        let finalOpenSpanCount = await recorder.openSpanCount()
        XCTAssertEqual(finalOpenSpanCount, 0)
    }

    func test_startupTelemetryReplacementSkipsStaleGeneratorAndRunsLatest() async throws {
        for gatedEvent in [TelemetryEventName.turnStarted, .inputTextReceived] {
            let firstTurnID = TelemetryTurnID("turn-startup-first")
            let secondTurnID = TelemetryTurnID("turn-startup-latest")
            let generator = CountingResponseGenerator()
            let sink = GatedFirstTerminalTelemetrySink(gatedEvent: gatedEvent)
            let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 1_700, step: 10), sinks: [sink])
            let session = AssistantSession(
                generator: generator, actionHost: FakeActionHost(),
                auditStore: InMemoryAuditStore(), telemetryRecorder: recorder
            )
            let firstSubmit = Task {
                await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Private stale input."))
            }
            await sink.waitForFirstTerminal()
            let latestOutcome = await session.submitText(
                AssistantTextRequest(turnID: secondTurnID, text: "Private latest input.")
            )
            await sink.releaseFirstTerminal()
            let firstOutcome = await firstSubmit.value
            let staleCallCount = await generator.callCount(for: firstTurnID)
            let latestCallCount = await generator.callCount(for: secondTurnID)
            let openSpanCount = await recorder.openSpanCount()
            let events = await sink.snapshot()
            XCTAssertEqual(staleCallCount, 0, "gate: \(gatedEvent)")
            XCTAssertEqual(latestCallCount, 1)
            XCTAssertEqual(firstOutcome, .cancelled(AssistantTurnCancellation(
                turnID: firstTurnID, message: "Okay, I moved on to the latest request."
            )))
            XCTAssertEqual(latestOutcome, .result(AssistantTurnResult(turnID: secondTurnID, message: "Latest response.")))
            XCTAssertEventNames(events.filter { $0.turnID == firstTurnID }, [.turnStarted, .inputTextReceived, .turnCancelled])
            XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
            XCTAssertEqual(openSpanCount, 0)
            XCTAssertNoVisibleRequestContent("Private stale input.", in: events)
            XCTAssertNoVisibleRequestContent("Private latest input.", in: events)
        }
    }

    func test_failureFixtureMatrixReportsCurrentFailuresWithVettedMetadata() async throws {
        for fixture in SubmitFailureFixture.allCases {
            let turnID = TelemetryTurnID("turn-current-\(fixture.rawValue)")
            let sink = InMemoryTelemetrySink()
            let auditStore = InMemoryAuditStore()
            let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 1_800, step: 10), sinks: [sink])
            let session = AssistantSession(
                generator: FailureFixtureGenerator(fixture: fixture, failingTurnID: turnID),
                actionHost: fixture.host, auditStore: auditStore, telemetryRecorder: recorder
            )
            let outcome = await session.submitText(AssistantTextRequest(turnID: turnID, text: "Private failed request."))
            let events = await sink.snapshot()
            let openSpanCount = await recorder.openSpanCount()
            let pending = await session.pendingProposal()
            let auditEntries = await auditStore.entries()
            XCTAssertEqual(outcome, .failure(AssistantTurnFailure(turnID: turnID, message: fixture.message)))
            XCTAssertEventNames(events, fixture.eventNames)
            XCTAssertTurnMetadata(events, turnID: turnID)
            let failureEvent = try XCTUnwrap(events.last)
            XCTAssertEventField(failureEvent, key: "resultCategory", equals: .string(fixture.rawValue))
            if let action = fixture.action {
                XCTAssertEventField(failureEvent, key: "actionName", equals: .string(action.name))
                XCTAssertEventField(failureEvent, key: "actionDomain", equals: .string(action.domain.rawValue))
                XCTAssertEventField(failureEvent, key: "actionKind", equals: .string(action.kind.rawValue))
            } else {
                for key in ["actionName", "actionDomain", "actionKind"] {
                    XCTAssertNoEventField(failureEvent, key: key)
                }
            }
            XCTAssertEqual(openSpanCount, 0)
            XCTAssertNil(pending)
            XCTAssertTrue(auditEntries.isEmpty)
            XCTAssertNoVisibleRequestContent("Private failed request.", in: events)
            XCTAssertNoVisibleRequestContent("Private fixture failure.", in: events)
            XCTAssertNoVisibleRequestContent("Private unsupported output.", in: events)
        }
    }

    func test_failureFixtureMatrixReplacementSuppressesStaleFailureWithoutDuplicateTerminal() async throws {
        for fixture in SubmitFailureFixture.allCases {
            try await self.assertFailureReplacement(fixture: fixture, gatedEvent: .turnFailed, expectedFirstEvents: fixture.eventNames)
        }
    }

    func test_readFailureReplacementDuringActionFailureCancelsOnlyOpenTurnSpan() async throws {
        try await self.assertFailureReplacement(
            fixture: .action, gatedEvent: .actionExecutionFailed,
            expectedFirstEvents: [.turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionFailed, .turnCancelled]
        )
    }

    private func assertFailureReplacement(
        fixture: SubmitFailureFixture,
        gatedEvent: TelemetryEventName,
        expectedFirstEvents: [TelemetryEventName]
    ) async throws {
        let firstTurnID = TelemetryTurnID("turn-failure-\(fixture.rawValue)")
        let secondTurnID = TelemetryTurnID("turn-failure-latest")
        let sink = GatedFirstTerminalTelemetrySink(gatedEvent: gatedEvent)
        let auditStore = InMemoryAuditStore()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 1_900, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: FailureFixtureGenerator(fixture: fixture, failingTurnID: firstTurnID),
            actionHost: fixture.host, auditStore: auditStore, telemetryRecorder: recorder
        )
        let firstSubmit = Task {
            await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Private failed request."))
        }
        await sink.waitForFirstTerminal()
        let latestOutcome = await session.submitText(
            AssistantTextRequest(turnID: secondTurnID, text: "Private latest request.")
        )
        await sink.releaseFirstTerminal()
        let firstOutcome = await firstSubmit.value
        let events = await sink.snapshot()
        let openSpanCount = await recorder.openSpanCount()
        let pending = await session.pendingProposal()
        let auditEntries = await auditStore.entries()
        XCTAssertEqual(firstOutcome, .cancelled(AssistantTurnCancellation(
            turnID: firstTurnID, message: "Okay, I moved on to the latest request."
        )), "fixture: \(fixture.rawValue), gate: \(gatedEvent)")
        XCTAssertEqual(latestOutcome, .result(AssistantTurnResult(turnID: secondTurnID, message: "Latest response.")))
        XCTAssertEventNames(events.filter { $0.turnID == firstTurnID }, expectedFirstEvents)
        XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
        XCTAssertEqual(openSpanCount, 0)
        XCTAssertNil(pending)
        XCTAssertTrue(auditEntries.isEmpty)
        XCTAssertNoVisibleRequestContent("Private failed request.", in: events)
        XCTAssertNoVisibleRequestContent("Private latest request.", in: events)
        XCTAssertNoVisibleRequestContent("Private fixture failure.", in: events)
        XCTAssertNoVisibleRequestContent("Private unsupported output.", in: events)
    }

    func test_submitText_mutationReturnsProposalWithoutExecutingMutation() async throws {
        let turnID = TelemetryTurnID("turn-proposal")
        let request = AssistantTextRequest(turnID: turnID, text: "Create a reminder to submit expenses.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "reminders.create"))
        let host = FakeActionHost()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 2_000, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let outcome = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let approvedExecutionCount = await host.approvedExecutionCount()
        let readExecutionCount = await host.readExecutionCount()
        let invocationCount = await host.invocationCount()
        let openSpanCount = await recorder.openSpanCount()
        let proposal = try XCTUnwrap(pendingProposal)
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .proposal(AssistantTurnProposal(turnID: turnID, proposal: proposal, message: proposal.summary))
        )
        XCTAssertEqual(proposal.action.name, "reminders.create")
        XCTAssertEqual(proposal.summary, "Create reminder: Send the report?")
        XCTAssertEqual(proposal.confirmationLabel, "Create reminder")
        XCTAssertNotNil(proposal.proposalID)
        XCTAssertEqual(approvedExecutionCount, 0)
        XCTAssertEqual(readExecutionCount, 0)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEventNames(events, [.turnStarted, .inputTextReceived, .actionProposalCreated])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[2], key: "phase", equals: .string("action"))
        XCTAssertEventField(events[2], key: "state", equals: .string("proposal_created"))
        XCTAssertEventField(events[2], key: "actionName", equals: .string("reminders.create"))
        XCTAssertEqual(openSpanCount, 1)
    }

    func test_submitText_failsIfMutationHostExecutesBeforeApproval() async throws {
        let turnID = TelemetryTurnID("turn-unsafe-mutation-host")
        let request = AssistantTextRequest(turnID: turnID, text: "Create a reminder unsafely.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "reminders.create"))
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 2_500, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: UnsafeMutationActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let outcome = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .failure(
                AssistantTurnFailure(
                    turnID: turnID,
                    message: "Sorry, that action needs confirmation before I can run it."
                )
            )
        )
        XCTAssertNil(pendingProposal)
        XCTAssertEventNames(events, [.turnStarted, .inputTextReceived, .turnFailed])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[2], key: "resultCategory", equals: .string("mutation_executed_without_approval"))
        XCTAssertEventField(events[2], key: "actionName", equals: .string("reminders.create"))
        XCTAssertEventField(events[2], key: "actionDomain", equals: .string("reminders"))
        XCTAssertEventField(events[2], key: "actionKind", equals: .string("mutation"))
        XCTAssertNoVisibleRequestContent("Unsafe pre-approval execution.", in: events)
        let openSpanCount = await recorder.openSpanCount()
        XCTAssertEqual(openSpanCount, 0)
    }

    func test_approve_executesPendingProposalExactlyOnceAndRecordsAuditEntry() async throws {
        let turnID = TelemetryTurnID("turn-approve")
        let request = AssistantTextRequest(turnID: turnID, text: "Create a reminder to send the report.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "reminders.create"))
        let host = FakeActionHost()
        let auditStore = InMemoryAuditStore()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_000, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )

        _ = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let proposal = try XCTUnwrap(pendingProposal)

        let outcome = try await session.approve(proposal: proposal)
        let pendingAfterApproval = await session.pendingProposal()
        let approvedExecutionCount = await host.approvedExecutionCount()

        XCTAssertEqual(
            outcome,
            .result(AssistantTurnResult(turnID: turnID, message: "Created reminder: Send the report."))
        )
        XCTAssertNil(pendingAfterApproval)
        XCTAssertEqual(approvedExecutionCount, 1)

        await XCTAssertThrowsErrorAsync(try await session.approve(proposal: proposal)) { error in
            XCTAssertEqual(error as? AssistantSessionError, .noPendingProposal)
        }

        let approvedExecutionCountAfterRetry = await host.approvedExecutionCount()
        let auditEntries = await auditStore.entries()
        let events = await sink.snapshot()

        XCTAssertEqual(approvedExecutionCountAfterRetry, 1)
        XCTAssertEqual(
            auditEntries,
            [
                AuditEntry(
                    turnID: turnID,
                    actionName: "reminders.create",
                    actionDomain: .reminders,
                    actionKind: .mutation,
                    summary: "Created reminder: Send the report."
                )
            ]
        )
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .actionProposalApproved,
                .actionExecutionStarted,
                .actionExecutionCompleted,
                .auditEntryRecorded,
                .turnCompleted
            ]
        )
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[3], key: "state", equals: .string("proposal_approved"))
        XCTAssertEventField(events[4], key: "actionKind", equals: .string("mutation"))
        XCTAssertEventField(events[5], key: "resultCategory", equals: .string("executed"))
        XCTAssertEventField(events[5], key: "durationMilliseconds", equals: .integer(10))
        XCTAssertEventField(events[6], key: "phase", equals: .string("audit"))
        XCTAssertEventField(events[6], key: "count", equals: .integer(1))
        XCTAssertEventField(events[7], key: "resultCategory", equals: .string("executed"))
        XCTAssertEventField(events[7], key: "durationMilliseconds", equals: .integer(70))
    }

    func test_approvedMutationIsAuditedBeforeCompletionTelemetryCanBlock() async throws {
        let turnID = TelemetryTurnID("turn-audit-before-telemetry")
        let request = AssistantTextRequest(turnID: turnID, text: "Create a private reminder.")
        let host = FakeActionHost()
        let auditStore = InMemoryAuditStore()
        let sink = GatedFirstTerminalTelemetrySink(gatedEvent: .actionExecutionCompleted)
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_050, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: FakeStructuredOutputGenerator(output: .action(name: "reminders.create")),
            actionHost: host, auditStore: auditStore, telemetryRecorder: recorder
        )
        _ = await session.submitText(request)
        let pending = await session.pendingProposal()
        let proposal = try XCTUnwrap(pending)
        let approval = Task { try await session.approve(proposal: proposal) }
        await sink.waitForFirstTerminal()

        let entriesWhileBlocked = await auditStore.entries()
        let executionsWhileBlocked = await host.approvedExecutionCount()
        let eventsWhileBlocked = await sink.snapshot()
        XCTAssertEqual(entriesWhileBlocked, [AuditEntry(
            turnID: turnID, actionName: "reminders.create", actionDomain: .reminders,
            actionKind: .mutation, summary: "Created reminder: Send the report."
        )])
        XCTAssertEqual(executionsWhileBlocked, 1)
        XCTAssertEventNames(eventsWhileBlocked, [
            .turnStarted, .inputTextReceived, .actionProposalCreated,
            .actionProposalApproved, .actionExecutionStarted, .actionExecutionCompleted
        ])
        await XCTAssertThrowsErrorAsync(try await session.approve(proposal: proposal)) { error in
            XCTAssertEqual(error as? AssistantSessionError, .noPendingProposal)
        }
        await sink.releaseFirstTerminal()

        let outcome = try await approval.value
        let finalEntries = await auditStore.entries()
        let finalExecutionCount = await host.approvedExecutionCount()
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()
        XCTAssertEqual(outcome, .result(AssistantTurnResult(turnID: turnID, message: "Created reminder: Send the report.")))
        XCTAssertEqual(finalEntries, entriesWhileBlocked)
        XCTAssertEqual(finalExecutionCount, 1)
        XCTAssertEqual(openSpanCount, 0)
        XCTAssertEventNames(events, [
            .turnStarted, .inputTextReceived, .actionProposalCreated, .actionProposalApproved,
            .actionExecutionStarted, .actionExecutionCompleted, .auditEntryRecorded, .turnCompleted
        ])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertEventField(events[6], key: "count", equals: .integer(1))
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertNoVisibleRequestContent("Created reminder: Send the report.", in: events)
    }

    func test_approvalSuccessReplacementMatrixContinuesExecutionButSuppressesOldResult() async throws {
        for actionName in ["reminders.create", "calendar.query"] {
            var gates: [ApprovalGate] = [
                .event(.actionProposalApproved), .event(.actionExecutionStarted), .host,
                .event(.actionExecutionCompleted), .event(.turnCompleted)
            ]
            if actionName == "reminders.create" {
                gates += [.audit, .event(.auditEntryRecorded)]
            }
            for gate in gates {
                try await self.assertApprovalReplacement(actionName: actionName, fixture: .executed, gate: gate)
            }
        }
    }

    func test_approvalFailureReplacementMatrixClosesSpansButSuppressesOldErrors() async throws {
        for actionName in ["reminders.create", "calendar.query"] {
            for fixture in [ApprovalResultFixture.thrown, .proposed, .wrongKind, .wrongName, .wrongDomain] {
                var gates: [ApprovalGate] = [.event(.actionProposalApproved), .event(.actionExecutionStarted), .host]
                gates += [.event(.actionExecutionFailed), .event(.turnFailed)]
                if fixture.isMismatch && actionName == "reminders.create" {
                    gates += [.audit, .event(.auditEntryRecorded)]
                }
                for gate in gates {
                    try await self.assertApprovalReplacement(actionName: actionName, fixture: fixture, gate: gate)
                }
            }
        }
    }

    private func assertApprovalReplacement(actionName: String, fixture: ApprovalResultFixture, gate: ApprovalGate) async throws {
        let firstTurnID = TelemetryTurnID("turn-approved-first")
        let secondTurnID = TelemetryTurnID("turn-approved-latest")
        let approvedAction = try XCTUnwrap(ActionCatalog.v2Default.action(named: actionName))
        let host = ApprovalFixtureHost(fixture: fixture, gateExecution: gate == .host)
        let auditStore = GatedApprovalAuditStore(gateRecord: gate == .audit)
        let sink = GatedFirstTerminalTelemetrySink(
            gatedEvent: gate.eventName ?? .bargeDetected,
            skipFirstMatches: actionName == "calendar.query" && gate.eventName == .actionExecutionStarted ? 1 : 0
        )
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_060, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: SequencedStructuredOutputGenerator(outputs: [.action(name: actionName), .action(name: "reminders.create")]),
            actionHost: host, auditStore: auditStore, telemetryRecorder: recorder
        )
        _ = await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Private approved request."))
        let pending = await session.pendingProposal()
        let firstProposal = try XCTUnwrap(pending)
        let approval = Task { try await session.approve(proposal: firstProposal) }
        switch gate {
        case .host: await host.waitForExecution()
        case .audit: await auditStore.waitForRecord()
        case .event: await sink.waitForFirstTerminal()
        }
        let latestOutcome = await session.submitText(AssistantTextRequest(turnID: secondTurnID, text: "Private latest request."))
        let latestPending = await session.pendingProposal()
        let latestProposal = try XCTUnwrap(latestPending)
        switch gate {
        case .host: await host.releaseExecution()
        case .audit: await auditStore.releaseRecord()
        case .event: await sink.releaseFirstTerminal()
        }
        switch await approval.result {
        case .success(let outcome):
            XCTAssertEqual(outcome, .cancelled(AssistantTurnCancellation(
                turnID: firstTurnID, message: "Okay, I moved on to the latest request."
            )), "\(actionName), \(fixture), \(gate)")
        case .failure:
            XCTFail("Stale approval threw: \(actionName), \(fixture), \(gate)")
        }
        let finalPending = await session.pendingProposal()
        let executionCount = await host.executionCount()
        let entries = await auditStore.entries()
        let events = await sink.snapshot()
        let firstEvents = events.filter { $0.turnID == firstTurnID }
        let openSpanCount = await recorder.openSpanCount()
        XCTAssertEqual(latestOutcome, .proposal(AssistantTurnProposal(
            turnID: secondTurnID, proposal: latestProposal, message: latestProposal.summary
        )))
        XCTAssertEqual(finalPending, latestProposal)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(openSpanCount, 1)
        XCTAssertEventNames(firstEvents, fixture.eventNames(for: approvedAction))
        XCTAssertEqual(entries.count, approvedAction.kind == .mutation && fixture.reportsExecution ? 1 : 0)
        if let entry = entries.first {
            XCTAssertEqual(entry.actionName, approvedAction.name)
            XCTAssertEqual(entry.actionKind, approvedAction.kind)
            XCTAssertEqual(entry.actionDomain, approvedAction.domain)
        }
        self.assertApprovedIdentityAndPrivacy(firstEvents, action: approvedAction)
        XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
        _ = try await session.reject(proposal: latestProposal)
        let finalOpenSpanCount = await recorder.openSpanCount()
        XCTAssertEqual(finalOpenSpanCount, 0)
    }

    func test_currentApprovalFailuresRetainTypedErrorsWithoutAudit() async throws {
        for actionName in ["reminders.create", "calendar.query"] {
            for fixture in [ApprovalResultFixture.thrown, .proposed] {
                let turnID = TelemetryTurnID("turn-current-approval-failure")
                let store = InMemoryAuditStore()
                let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_065, step: 10))
                let session = AssistantSession(
                    generator: FakeStructuredOutputGenerator(output: .action(name: actionName)),
                    actionHost: ApprovalFixtureHost(fixture: fixture), auditStore: store, telemetryRecorder: recorder
                )
                _ = await session.submitText(AssistantTextRequest(turnID: turnID, text: "Current failing approval."))
                let pending = await session.pendingProposal()
                let proposal = try XCTUnwrap(pending)
                await XCTAssertThrowsErrorAsync(try await session.approve(proposal: proposal)) { error in
                    if fixture == .thrown {
                        XCTAssertTrue(error is FailureFixtureError)
                    } else {
                        XCTAssertEqual(error as? AssistantSessionError, .proposalMismatch(expected: proposal, received: proposal))
                    }
                }
                let entries = await store.entries()
                let openSpanCount = await recorder.openSpanCount()
                XCTAssertTrue(entries.isEmpty)
                XCTAssertEqual(openSpanCount, 0)
            }
        }
    }

    func test_approvedExecutionMismatchUsesApprovedAuditScopeAndPrivateReturnedMetadata() async throws {
        for actionName in ["reminders.create", "calendar.query"] {
            for fixture in [ApprovalResultFixture.wrongKind, .wrongName, .wrongDomain] {
                let turnID = TelemetryTurnID("turn-approved-mismatch")
                let action = try XCTUnwrap(ActionCatalog.v2Default.action(named: actionName))
                let host = ApprovalFixtureHost(fixture: fixture)
                let auditStore = InMemoryAuditStore()
                let sink = InMemoryTelemetrySink()
                let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_070, step: 10), sinks: [sink])
                let session = AssistantSession(
                    generator: FakeStructuredOutputGenerator(output: .action(name: actionName)),
                    actionHost: host, auditStore: auditStore, telemetryRecorder: recorder
                )
                _ = await session.submitText(AssistantTextRequest(turnID: turnID, text: "Private approved request."))
                let pending = await session.pendingProposal()
                let proposal = try XCTUnwrap(pending)
                await XCTAssertThrowsErrorAsync(try await session.approve(proposal: proposal)) { error in
                    guard case AssistantSessionError.executedActionMismatch(let expected, let received) = error else {
                        return XCTFail("Expected typed executed-action mismatch")
                    }
                    XCTAssertEqual(expected, action)
                    XCTAssertNotEqual(received, action)
                }
                let entries = await auditStore.entries()
                let events = await sink.snapshot()
                let executionCount = await host.executionCount()
                let openSpanCount = await recorder.openSpanCount()
                XCTAssertEqual(entries.count, action.kind == .mutation ? 1 : 0)
                if let entry = entries.first {
                    XCTAssertEqual(entry, AuditEntry(
                        turnID: turnID, actionName: action.name, actionDomain: action.domain, actionKind: action.kind,
                        summary: "Approved mutation reported execution, but Ora could not verify the returned action metadata."
                    ))
                }
                XCTAssertEqual(executionCount, 1)
                XCTAssertEqual(openSpanCount, 0)
                XCTAssertEventNames(events, fixture.eventNames(for: action))
                self.assertApprovedIdentityAndPrivacy(events, action: action)
                XCTAssertTurnMetadata(events, turnID: turnID)
            }
        }
    }

    private func assertApprovedIdentityAndPrivacy(_ events: [TelemetryEvent], action: Action) {
        for event in events {
            if event.fields.contains(where: { $0.key == "actionName" }) {
                XCTAssertEventField(event, key: "actionName", equals: .string(action.name))
                XCTAssertEventField(event, key: "actionDomain", equals: .string(action.domain.rawValue))
                XCTAssertEventField(event, key: "actionKind", equals: .string(action.kind.rawValue))
            }
        }
        XCTAssertNoVisibleRequestContent("Private unvetted returned action.", in: events)
        XCTAssertNoVisibleRequestContent("Private execution summary.", in: events)
        XCTAssertNoVisibleRequestContent("Private fixture failure.", in: events)
        XCTAssertNoVisibleRequestContent("Private approved request.", in: events)
    }

    func test_hostCallbackIdentityMismatchIsRejectedBeforeProposalOrReadSuccess() async throws {
        for callback in HostCallbackFixture.allCases {
            let turnID = TelemetryTurnID("turn-host-callback-mismatch")
            let action = try XCTUnwrap(ActionCatalog.v2Default.action(named: callback.actionName))
            let host = CallbackIdentityHost(callback: callback, mismatched: true)
            let sink = InMemoryTelemetrySink()
            let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_080, step: 10), sinks: [sink])
            let auditStore = InMemoryAuditStore()
            let session = AssistantSession(
                generator: FakeStructuredOutputGenerator(output: .action(name: action.name)),
                actionHost: host, auditStore: auditStore, telemetryRecorder: recorder
            )
            let outcome = await session.submitText(AssistantTextRequest(turnID: turnID, text: "Private callback request."))
            guard case .failure = outcome else {
                XCTFail("Unverified host callback accepted: \(callback)")
                continue
            }
            let pending = await session.pendingProposal()
            let entries = await auditStore.entries()
            let events = await sink.snapshot()
            let openSpanCount = await recorder.openSpanCount()
            XCTAssertNil(pending)
            XCTAssertTrue(entries.isEmpty)
            XCTAssertEqual(openSpanCount, 0)
            XCTAssertFalse(events.contains { $0.name == .actionProposalCreated || $0.name == .turnCompleted })
            let failure = try XCTUnwrap(events.last)
            XCTAssertEqual(failure.name, .turnFailed)
            XCTAssertEventField(failure, key: "actionName", equals: .string(action.name))
            XCTAssertEventField(failure, key: "actionDomain", equals: .string(action.domain.rawValue))
            XCTAssertEventField(failure, key: "actionKind", equals: .string(action.kind.rawValue))
            XCTAssertNoVisibleRequestContent("Private unvetted returned action.", in: events)
            XCTAssertNoVisibleRequestContent("Private callback request.", in: events)
            XCTAssertTurnMetadata(events, turnID: turnID)
        }
    }

    func test_matchedHostCallbackIdentityRetainsNormalProposalAndReadOutcomes() async throws {
        for callback in HostCallbackFixture.allCases {
            let turnID = TelemetryTurnID("turn-host-callback-control")
            let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_090, step: 10))
            let session = AssistantSession(
                generator: FakeStructuredOutputGenerator(output: .action(name: callback.actionName)),
                actionHost: CallbackIdentityHost(callback: callback, mismatched: false),
                auditStore: InMemoryAuditStore(), telemetryRecorder: recorder
            )
            let outcome = await session.submitText(AssistantTextRequest(turnID: turnID, text: "Matched request."))
            if callback == .readExecuted {
                XCTAssertEqual(outcome, .result(AssistantTurnResult(turnID: turnID, message: "Matched read result.")))
            } else {
                let pending = await session.pendingProposal()
                let proposal = try XCTUnwrap(pending)
                XCTAssertEqual(outcome, .proposal(AssistantTurnProposal(turnID: turnID, proposal: proposal, message: proposal.summary)))
                _ = try await session.reject(proposal: proposal)
            }
            let openSpanCount = await recorder.openSpanCount()
            XCTAssertEqual(openSpanCount, 0)
        }
    }

    func test_approveReadProposalExecutesOnceWithoutAuditEntryOrAuditTelemetry() async throws {
        let turnID = TelemetryTurnID("turn-approve-read")
        let request = AssistantTextRequest(turnID: turnID, text: "Look up my private calendar.")
        let host = ReadProposalActionHost()
        let auditStore = InMemoryAuditStore()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_100, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: FakeStructuredOutputGenerator(output: .action(name: "calendar.query")),
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )

        _ = await session.submitText(request)
        let pending = await session.pendingProposal()
        let proposal = try XCTUnwrap(pending)
        let outcome = try await session.approve(proposal: proposal)
        await XCTAssertThrowsErrorAsync(try await session.approve(proposal: proposal)) { error in
            XCTAssertEqual(error as? AssistantSessionError, .noPendingProposal)
        }

        let approvedExecutionCount = await host.approvedExecutionCount()
        let finalPending = await session.pendingProposal()
        let auditEntries = await auditStore.entries()
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()
        XCTAssertEqual(
            outcome,
            .result(AssistantTurnResult(turnID: turnID, message: "Approved read proposal."))
        )
        XCTAssertEqual(approvedExecutionCount, 1)
        XCTAssertNil(finalPending)
        XCTAssertTrue(auditEntries.isEmpty)
        XCTAssertFalse(events.contains { $0.name == .auditEntryRecorded })
        XCTAssertEqual(openSpanCount, 0)
        XCTAssertEventNames(events, [
            .turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionCancelled,
            .actionProposalCreated, .actionProposalApproved, .actionExecutionStarted,
            .actionExecutionCompleted, .turnCompleted
        ])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertNoVisibleRequestContent("Approved read proposal.", in: events)
        XCTAssertEventField(events[7], key: "actionKind", equals: .string("read"))
        XCTAssertEventField(events[7], key: "resultCategory", equals: .string("executed"))
        XCTAssertEventField(events[7], key: "durationMilliseconds", equals: .integer(10))
    }

    func test_approveWithDefaultActionHostExecutesBoundProposalAndRecordsAudit() async throws {
        let turnID = TelemetryTurnID("turn-default-host-approve")
        let request = AssistantTextRequest(turnID: turnID, text: "Create a calendar event.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "calendar.create"))
        let auditStore = InMemoryAuditStore()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_250, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: ActionHost(catalog: .v2Default),
            auditStore: auditStore,
            telemetryRecorder: recorder
        )

        _ = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let proposal = try XCTUnwrap(pendingProposal)
        XCTAssertNotNil(proposal.proposalID)

        let outcome = try await session.approve(proposal: proposal)
        let auditEntries = await auditStore.entries()
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .result(AssistantTurnResult(turnID: turnID, message: "calendar.create executed."))
        )
        XCTAssertEqual(
            auditEntries,
            [
                AuditEntry(
                    turnID: turnID,
                    actionName: "calendar.create",
                    actionDomain: .calendar,
                    actionKind: .mutation,
                    summary: "calendar.create executed."
                )
            ]
        )
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .actionProposalApproved,
                .actionExecutionStarted,
                .actionExecutionCompleted,
                .auditEntryRecorded,
                .turnCompleted
            ]
        )
    }

    func test_concurrentApprovalAttemptsExecutePendingMutationExactlyOnce() async throws {
        let turnID = TelemetryTurnID("turn-concurrent-approval")
        let request = AssistantTextRequest(turnID: turnID, text: "Create a reminder to send the report.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "reminders.create"))
        let host = GatedActionHost()
        let auditStore = InMemoryAuditStore()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_500, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )

        _ = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let proposal = try XCTUnwrap(pendingProposal)

        let firstApproval = Task {
            try await session.approve(proposal: proposal)
        }
        await host.waitForFirstApprovedExecution()

        let secondApproval = Task {
            try await session.approve(proposal: proposal)
        }
        await XCTAssertThrowsErrorAsync(try await secondApproval.value) { error in
            XCTAssertEqual(error as? AssistantSessionError, .noPendingProposal)
        }

        await host.releaseFirstApprovedExecution()
        let firstOutcome = try await firstApproval.value
        let approvedExecutionCount = await host.approvedExecutionCount()
        let auditEntries = await auditStore.entries()
        let events = await sink.snapshot()

        XCTAssertEqual(
            firstOutcome,
            .result(AssistantTurnResult(turnID: turnID, message: "Created reminder: Send the report."))
        )
        XCTAssertEqual(approvedExecutionCount, 1)
        XCTAssertEqual(auditEntries.count, 1)
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .actionProposalApproved,
                .actionExecutionStarted,
                .actionExecutionCompleted,
                .auditEntryRecorded,
                .turnCompleted
            ]
        )
    }

    func test_overlappingSubmitTextDoesNotLetStaleGenerationOverwriteNewerPendingProposal() async throws {
        let firstTurnID = TelemetryTurnID("turn-overlap-first")
        let secondTurnID = TelemetryTurnID("turn-overlap-second")
        let generator = GatedFirstStructuredOutputGenerator(
            immediateOutputAfterFirst: .action(name: "reminders.create")
        )
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_600, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: FakeActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let firstTurn = Task {
            await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Create the first reminder."))
        }
        await generator.waitForFirstRequest()

        _ = await session.submitText(AssistantTextRequest(turnID: secondTurnID, text: "Create the second reminder."))
        let secondPendingProposal = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPendingProposal)

        await generator.releaseFirstRequest(with: .action(name: "reminders.create"))
        let firstOutcome = await firstTurn.value
        let pendingAfterFirstCompletionValue = await session.pendingProposal()
        let pendingAfterFirstCompletion = try XCTUnwrap(pendingAfterFirstCompletionValue)
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()

        XCTAssertEqual(
            firstOutcome,
            .cancelled(
                AssistantTurnCancellation(
                    turnID: firstTurnID,
                    message: "Okay, I moved on to the latest request."
                )
            )
        )
        XCTAssertEqual(pendingAfterFirstCompletion, secondProposal)
        XCTAssertNotNil(pendingAfterFirstCompletion.proposalID)
        XCTAssertEqual(openSpanCount, 1)
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .turnCancelled
            ]
        )
        XCTAssertEqual(events[4].turnID, secondTurnID)
        XCTAssertEqual(events[5].turnID, firstTurnID)
        XCTAssertEventField(events[5], key: "resultCategory", equals: .string("replaced"))
    }

    func test_submitTextReturnsCancellationIfProposalIsReplacedWhileTelemetryIsRecording() async throws {
        let firstTurnID = TelemetryTurnID("turn-proposal-telemetry-first")
        let secondTurnID = TelemetryTurnID("turn-proposal-telemetry-second")
        let generator = SequencedStructuredOutputGenerator(outputs: [
            .action(name: "reminders.create"),
            .action(name: "reminders.create")
        ])
        let sink = GatedFirstProposalTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_525, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: FakeActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let firstTurn = Task {
            await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Create first reminder."))
        }
        await sink.waitForFirstProposalRecord()

        _ = await session.submitText(AssistantTextRequest(turnID: secondTurnID, text: "Create second reminder."))
        let secondPendingProposal = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPendingProposal)

        await sink.releaseFirstProposalRecord()
        let firstOutcome = await firstTurn.value
        let pendingAfterFirstCompletionValue = await session.pendingProposal()
        let pendingAfterFirstCompletion = try XCTUnwrap(pendingAfterFirstCompletionValue)
        let openSpanCount = await recorder.openSpanCount()

        XCTAssertEqual(
            firstOutcome,
            .cancelled(
                AssistantTurnCancellation(
                    turnID: firstTurnID,
                    message: "Okay, I moved on to the latest request."
                )
            )
        )
        XCTAssertEqual(pendingAfterFirstCompletion, secondProposal)
        XCTAssertNotNil(pendingAfterFirstCompletion.proposalID)
        XCTAssertEqual(openSpanCount, 1)
        let events = await sink.snapshot()
        let firstEvents = events.filter { $0.turnID == firstTurnID }
        XCTAssertEventNames(firstEvents, [.turnStarted, .inputTextReceived, .actionProposalCreated, .turnCancelled])
        XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
        XCTAssertEventField(firstEvents[3], key: "resultCategory", equals: .string("replaced"))
        XCTAssertNoVisibleRequestContent("Create first reminder.", in: events)
        XCTAssertNoVisibleRequestContent("Create second reminder.", in: events)

        _ = try await session.reject(proposal: secondProposal)
        let finalOpenSpanCount = await recorder.openSpanCount()
        XCTAssertEqual(finalOpenSpanCount, 0)
    }

    func test_readPathReturnsCancellationIfProposalIsReplacedWhileTelemetryIsRecording() async throws {
        let firstTurnID = TelemetryTurnID("turn-read-telemetry-first")
        let secondTurnID = TelemetryTurnID("turn-read-telemetry-second")
        let firstRequest = AssistantTextRequest(turnID: firstTurnID, text: "Show my private calendar.")
        let secondRequest = AssistantTextRequest(turnID: secondTurnID, text: "Show my calendar again.")
        let generator = SequencedStructuredOutputGenerator(outputs: [
            .action(name: "calendar.query"),
            .action(name: "calendar.query")
        ])
        let host = ReadProposalActionHost()
        let auditStore = InMemoryAuditStore()
        let sink = GatedFirstProposalTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_540, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )

        let firstTurn = Task { await session.submitText(firstRequest) }
        await sink.waitForFirstProposalRecord()
        let secondOutcome = await session.submitText(secondRequest)
        let secondPending = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPending)

        await sink.releaseFirstProposalRecord()
        let firstOutcome = await firstTurn.value
        let pendingAfterFirstCompletion = await session.pendingProposal()
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()

        XCTAssertEqual(
            firstOutcome,
            .cancelled(AssistantTurnCancellation(turnID: firstTurnID, message: "Okay, I moved on to the latest request."))
        )
        XCTAssertEqual(
            secondOutcome,
            .proposal(AssistantTurnProposal(turnID: secondTurnID, proposal: secondProposal, message: secondProposal.summary))
        )
        XCTAssertEqual(pendingAfterFirstCompletion, secondProposal)
        XCTAssertNotNil(secondProposal.proposalID)
        XCTAssertEqual(openSpanCount, 1)
        let firstEvents = events.filter { $0.turnID == firstTurnID }
        let secondEvents = events.filter { $0.turnID == secondTurnID }
        XCTAssertEventNames(firstEvents, [
            .turnStarted, .inputTextReceived, .actionExecutionStarted,
            .actionExecutionCancelled, .actionProposalCreated, .turnCancelled
        ])
        XCTAssertEventNames(secondEvents, [
            .turnStarted, .inputTextReceived, .actionExecutionStarted,
            .actionExecutionCancelled, .actionProposalCreated
        ])
        XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
        XCTAssertEventField(firstEvents[5], key: "resultCategory", equals: .string("replaced"))
        XCTAssertNoVisibleRequestContent(firstRequest.text, in: events)
        XCTAssertNoVisibleRequestContent(secondRequest.text, in: events)

        _ = try await session.reject(proposal: secondProposal)
        let finalOpenSpanCount = await recorder.openSpanCount()
        let approvedExecutionCount = await host.approvedExecutionCount()
        let auditEntries = await auditStore.entries()
        XCTAssertEqual(finalOpenSpanCount, 0)
        XCTAssertEqual(approvedExecutionCount, 0)
        XCTAssertTrue(auditEntries.isEmpty)
    }

    func test_readPathDoesNotCreateProposalAfterReplacementDuringActionCancellationTelemetry() async throws {
        let firstTurnID = TelemetryTurnID("turn-read-cancellation-first")
        let secondTurnID = TelemetryTurnID("turn-read-cancellation-second")
        let generator = SequencedStructuredOutputGenerator(outputs: [
            .action(name: "calendar.query"),
            .action(name: "calendar.query")
        ])
        let sink = GatedFirstActionCancellationTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_542, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: ReadProposalActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let firstTurn = Task {
            await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Show my private calendar."))
        }
        await sink.waitForFirstActionCancellation()
        let secondOutcome = await session.submitText(
            AssistantTextRequest(turnID: secondTurnID, text: "Show my calendar instead.")
        )
        let secondPending = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPending)
        await sink.releaseFirstActionCancellation()

        let firstOutcome = await firstTurn.value
        let pendingAfterFirstCompletion = await session.pendingProposal()
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()
        let firstEvents = events.filter { $0.turnID == firstTurnID }
        XCTAssertEqual(
            firstOutcome,
            .cancelled(AssistantTurnCancellation(turnID: firstTurnID, message: "Okay, I moved on to the latest request."))
        )
        XCTAssertEqual(
            secondOutcome,
            .proposal(AssistantTurnProposal(turnID: secondTurnID, proposal: secondProposal, message: secondProposal.summary))
        )
        XCTAssertEqual(pendingAfterFirstCompletion, secondProposal)
        XCTAssertNotNil(secondProposal.proposalID)
        XCTAssertEqual(openSpanCount, 1)
        XCTAssertEventNames(firstEvents, [
            .turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionCancelled, .turnCancelled
        ])
        XCTAssertEqual(events.filter { $0.name == .actionProposalCreated }.map(\.turnID), [secondTurnID])
        XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
        XCTAssertNoVisibleRequestContent("Show my private calendar.", in: events)
        XCTAssertNoVisibleRequestContent("Show my calendar instead.", in: events)

        _ = try await session.reject(proposal: secondProposal)
        let finalOpenSpanCount = await recorder.openSpanCount()
        XCTAssertEqual(finalOpenSpanCount, 0)
    }

    func test_readPathDoesNotCreateRejectedProposalAfterActionCancellationTelemetryResumes() async throws {
        let turnID = TelemetryTurnID("turn-read-cancellation-rejected")
        let sink = GatedFirstActionCancellationTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_543, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: FakeStructuredOutputGenerator(output: .action(name: "calendar.query")),
            actionHost: ReadProposalActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )
        let submit = Task {
            await session.submitText(AssistantTextRequest(turnID: turnID, text: "Private lookup to reject."))
        }
        await sink.waitForFirstActionCancellation()
        let pending = await session.pendingProposal()
        let proposal = try XCTUnwrap(pending)
        _ = try await session.reject(proposal: proposal)
        await sink.releaseFirstActionCancellation()

        let outcome = await submit.value
        let finalPending = await session.pendingProposal()
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()
        XCTAssertEqual(
            outcome,
            .cancelled(AssistantTurnCancellation(turnID: turnID, message: "Okay, I moved on to the latest request."))
        )
        XCTAssertNil(finalPending)
        XCTAssertEqual(openSpanCount, 0)
        XCTAssertEventNames(events, [
            .turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionCancelled,
            .actionProposalRejected, .turnCancelled
        ])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent("Private lookup to reject.", in: events)
    }

    func test_mutationDoesNotReturnRejectedProposalAfterTelemetryResumes() async throws {
        try await self.assertRejectedProposalIsNotReturned(actionName: "reminders.create", host: FakeActionHost())
    }

    func test_readPathDoesNotReturnRejectedProposalAfterTelemetryResumes() async throws {
        try await self.assertRejectedProposalIsNotReturned(actionName: "calendar.query", host: ReadProposalActionHost())
    }

    private func assertRejectedProposalIsNotReturned(actionName: String, host: any ActionHosting) async throws {
        let turnID = TelemetryTurnID("turn-rejected-during-telemetry")
        let sink = GatedFirstProposalTelemetrySink()
        let auditStore = InMemoryAuditStore()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_545, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: FakeStructuredOutputGenerator(output: .action(name: actionName)),
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )
        let submit = Task {
            await session.submitText(AssistantTextRequest(turnID: turnID, text: "Private request to reject."))
        }
        await sink.waitForFirstProposalRecord()
        let pending = await session.pendingProposal()
        let proposal = try XCTUnwrap(pending)
        _ = try await session.reject(proposal: proposal)
        await sink.releaseFirstProposalRecord()

        let outcome = await submit.value
        let finalPending = await session.pendingProposal()
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()
        let auditEntries = await auditStore.entries()
        XCTAssertEqual(
            outcome,
            .cancelled(AssistantTurnCancellation(turnID: turnID, message: "Okay, I moved on to the latest request."))
        )
        XCTAssertNil(finalPending)
        XCTAssertEqual(openSpanCount, 0)
        XCTAssertTrue(auditEntries.isEmpty)
        XCTAssertEqual(events.suffix(2).map(\.name), [.actionProposalRejected, .turnCancelled])
        XCTAssertEqual(events.filter { $0.name == .turnCancelled }.count, 1)
        XCTAssertFalse(events.contains { $0.name == .actionProposalApproved || $0.name == .actionExecutionCompleted })
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent("Private request to reject.", in: events)
    }

    func test_readPathProposalIsBoundToTurnAndRejectsStaleApproval() async throws {
        let firstTurnID = TelemetryTurnID("turn-read-proposal-first")
        let secondTurnID = TelemetryTurnID("turn-read-proposal-second")
        let generator = SequencedStructuredOutputGenerator(outputs: [
            .action(name: "calendar.query"),
            .action(name: "calendar.query")
        ])
        let host = ReadProposalActionHost()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_550, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        _ = await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Show my calendar."))
        let firstPendingProposal = await session.pendingProposal()
        let firstProposal = try XCTUnwrap(firstPendingProposal)
        XCTAssertNotNil(firstProposal.proposalID)
        _ = try await session.reject(proposal: firstProposal)

        _ = await session.submitText(AssistantTextRequest(turnID: secondTurnID, text: "Show my calendar again."))
        let secondPendingProposal = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPendingProposal)
        XCTAssertNotNil(secondProposal.proposalID)
        XCTAssertNotEqual(firstProposal.proposalID, secondProposal.proposalID)
        XCTAssertNotEqual(firstProposal, secondProposal)

        await XCTAssertThrowsErrorAsync(try await session.approve(proposal: firstProposal)) { error in
            XCTAssertEqual(
                error as? AssistantSessionError,
                .proposalMismatch(expected: secondProposal, received: firstProposal)
            )
        }
        let approvedExecutionCount = await host.approvedExecutionCount()
        XCTAssertEqual(approvedExecutionCount, 0)
    }

    func test_overlappingReadActionDoesNotCompleteAfterNewerPendingProposal() async throws {
        let firstTurnID = TelemetryTurnID("turn-overlap-read-first")
        let secondTurnID = TelemetryTurnID("turn-overlap-read-second")
        let generator = SequencedStructuredOutputGenerator(outputs: [
            .action(name: "calendar.query"),
            .action(name: "reminders.create")
        ])
        let host = GatedReadActionHost()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_650, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let firstTurn = Task {
            await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "What is on my calendar?"))
        }
        await host.waitForReadExecution()

        _ = await session.submitText(AssistantTextRequest(turnID: secondTurnID, text: "Create a reminder instead."))
        let secondPendingProposal = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPendingProposal)

        await host.releaseReadExecution()
        let firstOutcome = await firstTurn.value
        let pendingAfterFirstCompletionValue = await session.pendingProposal()
        let pendingAfterFirstCompletion = try XCTUnwrap(pendingAfterFirstCompletionValue)
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()

        XCTAssertEqual(
            firstOutcome,
            .cancelled(
                AssistantTurnCancellation(
                    turnID: firstTurnID,
                    message: "Okay, I moved on to the latest request."
                )
            )
        )
        XCTAssertEqual(pendingAfterFirstCompletion, secondProposal)
        XCTAssertEqual(openSpanCount, 1)
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionExecutionStarted,
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .actionExecutionCancelled,
                .turnCancelled
            ]
        )
        XCTAssertEqual(events[6].turnID, firstTurnID)
        XCTAssertEventField(events[6], key: "resultCategory", equals: .string("replaced"))
        XCTAssertEqual(events[7].turnID, firstTurnID)
        XCTAssertEventField(events[7], key: "resultCategory", equals: .string("replaced"))
    }

    func test_submitText_replacesPendingProposalByCancellingPreviousTurnSpan() async throws {
        let firstTurnID = TelemetryTurnID("turn-replace-first")
        let secondTurnID = TelemetryTurnID("turn-replace-second")
        let generator = SequencedStructuredOutputGenerator(outputs: [
            .action(name: "reminders.create"),
            .action(name: "reminders.create")
        ])
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_700, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: FakeActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        _ = await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Create a reminder."))
        let firstPendingProposal = await session.pendingProposal()
        let firstProposal = try XCTUnwrap(firstPendingProposal)

        _ = await session.submitText(AssistantTextRequest(turnID: secondTurnID, text: "Create a replacement reminder."))
        let secondPendingProposal = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPendingProposal)
        let openSpanCount = await recorder.openSpanCount()
        let events = await sink.snapshot()

        XCTAssertNotEqual(firstProposal, secondProposal)
        XCTAssertEqual(openSpanCount, 1)
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .turnCancelled,
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated
            ]
        )
        XCTAssertEqual(events[3].turnID, firstTurnID)
        XCTAssertEventField(events[3], key: "resultCategory", equals: .string("replaced"))
        XCTAssertEventField(events[3], key: "durationMilliseconds", equals: .integer(30))
        XCTAssertEqual(events[4].turnID, secondTurnID)
    }

    func test_mutationProposalRejectsReplayWithReusedCallerTurnID() async throws {
        try await self.assertProposalReplayIsRejected(actionName: "reminders.create", crossSession: false)
    }

    func test_readProposalRejectsReplayWithReusedCallerTurnID() async throws {
        try await self.assertProposalReplayIsRejected(actionName: "calendar.query", crossSession: false)
    }

    func test_mutationProposalRejectsReplayAcrossSessionsWithSameCallerTurnID() async throws {
        try await self.assertProposalReplayIsRejected(actionName: "reminders.create", crossSession: true)
    }

    func test_readProposalRejectsReplayAcrossSessionsWithSameCallerTurnID() async throws {
        try await self.assertProposalReplayIsRejected(actionName: "calendar.query", crossSession: true)
    }

    private func assertProposalReplayIsRejected(actionName: String, crossSession: Bool) async throws {
        let request = AssistantTextRequest(turnID: TelemetryTurnID("caller-reused-turn"), text: "Identical private request.")
        let firstHost = ApprovalFixtureHost(fixture: .executed)
        let firstStore = InMemoryAuditStore()
        let firstRecorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_950, step: 10))
        let firstSession = AssistantSession(
            generator: FakeStructuredOutputGenerator(output: .action(name: actionName)),
            actionHost: firstHost, auditStore: firstStore, telemetryRecorder: firstRecorder
        )
        let firstOutcome = await firstSession.submitText(request)
        let firstPending = await firstSession.pendingProposal()
        let firstProposal = try XCTUnwrap(firstPending)
        let targetHost = crossSession ? ApprovalFixtureHost(fixture: .executed) : firstHost
        let targetStore = crossSession ? InMemoryAuditStore() : firstStore
        let targetRecorder = crossSession ? TelemetryRecorder(clock: TestTelemetryClock(start: 3_960, step: 10)) : firstRecorder
        let targetSession = crossSession ? AssistantSession(
            generator: FakeStructuredOutputGenerator(output: .action(name: actionName)),
            actionHost: targetHost, auditStore: targetStore, telemetryRecorder: targetRecorder
        ) : firstSession
        let latestOutcome = await targetSession.submitText(request)
        let latestPending = await targetSession.pendingProposal()
        let latestProposal = try XCTUnwrap(latestPending)
        XCTAssertEqual(firstOutcome, .proposal(AssistantTurnProposal(
            turnID: request.turnID, proposal: firstProposal, message: firstProposal.summary
        )))
        XCTAssertEqual(latestOutcome, .proposal(AssistantTurnProposal(
            turnID: request.turnID, proposal: latestProposal, message: latestProposal.summary
        )))
        XCTAssertTrue(firstProposal.hasSameConfirmationContent(as: latestProposal))
        let firstID = try XCTUnwrap(firstProposal.proposalID)
        let latestID = try XCTUnwrap(latestProposal.proposalID)
        XCTAssertFalse(firstID.isEmpty)
        XCTAssertFalse(latestID.isEmpty)
        XCTAssertNotEqual(firstID, latestID)
        await XCTAssertThrowsErrorAsync(try await targetSession.approve(proposal: firstProposal)) { error in
            XCTAssertEqual(error as? AssistantSessionError, .proposalMismatch(expected: latestProposal, received: firstProposal))
        }
        let pendingAfterReplay = await targetSession.pendingProposal()
        let countAfterReplay = await targetHost.executionCount()
        let entriesAfterReplay = await targetStore.entries()
        XCTAssertEqual(pendingAfterReplay, latestProposal)
        XCTAssertEqual(countAfterReplay, 0)
        XCTAssertTrue(entriesAfterReplay.isEmpty)

        if pendingAfterReplay != nil {
            let outcome = try await targetSession.approve(proposal: latestProposal)
            XCTAssertEqual(outcome, .result(AssistantTurnResult(turnID: request.turnID, message: "Private execution summary.")))
            let executionCount = await targetHost.executionCount()
            let entries = await targetStore.entries()
            XCTAssertEqual(executionCount, 1)
            XCTAssertEqual(entries.count, latestProposal.action.kind == .mutation ? 1 : 0)
        }
        let targetOpenSpanCount = await targetRecorder.openSpanCount()
        XCTAssertEqual(targetOpenSpanCount, 0)
        if crossSession {
            _ = try await firstSession.reject(proposal: firstProposal)
            let firstOpenSpanCount = await firstRecorder.openSpanCount()
            let firstExecutionCount = await firstHost.executionCount()
            let firstEntries = await firstStore.entries()
            XCTAssertEqual(firstOpenSpanCount, 0)
            XCTAssertEqual(firstExecutionCount, 0)
            XCTAssertTrue(firstEntries.isEmpty)
        }
    }

    func test_staleSameActionProposalCannotApproveLaterTurn() async throws {
        let firstTurnID = TelemetryTurnID("turn-stale-first")
        let secondTurnID = TelemetryTurnID("turn-stale-second")
        let generator = SequencedStructuredOutputGenerator(outputs: [
            .action(name: "reminders.create"),
            .action(name: "reminders.create")
        ])
        let host = FakeActionHost()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_800, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        _ = await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Create a reminder."))
        let firstPendingProposal = await session.pendingProposal()
        let firstProposal = try XCTUnwrap(firstPendingProposal)
        _ = try await session.reject(proposal: firstProposal)

        _ = await session.submitText(AssistantTextRequest(turnID: secondTurnID, text: "Create a reminder again."))
        let secondPendingProposal = await session.pendingProposal()
        let secondProposal = try XCTUnwrap(secondPendingProposal)

        XCTAssertNotEqual(firstProposal, secondProposal)
        await XCTAssertThrowsErrorAsync(try await session.approve(proposal: firstProposal)) { error in
            XCTAssertEqual(
                error as? AssistantSessionError,
                .proposalMismatch(expected: secondProposal, received: firstProposal)
            )
        }
        let approvedExecutionCount = await host.approvedExecutionCount()
        XCTAssertEqual(approvedExecutionCount, 0)
    }

    func test_approvedActionFailureClosesActionAndTurnSpansWithFailureTelemetry() async throws {
        let turnID = TelemetryTurnID("turn-approved-action-fails")
        let request = AssistantTextRequest(turnID: turnID, text: "Create a reminder to send the report.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "reminders.create"))
        let host = ThrowingApprovedActionHost()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_900, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        _ = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let proposal = try XCTUnwrap(pendingProposal)

        await XCTAssertThrowsErrorAsync(try await session.approve(proposal: proposal)) { error in
            XCTAssertEqual(error as? TestActionHostError, .approvedExecutionFailed)
        }

        let events = await sink.snapshot()
        let openSpanCount = await recorder.openSpanCount()

        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .actionProposalApproved,
                .actionExecutionStarted,
                .actionExecutionFailed,
                .turnFailed
            ]
        )
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[5], key: "resultCategory", equals: .string("action_failed"))
        XCTAssertEventField(events[5], key: "durationMilliseconds", equals: .integer(10))
        XCTAssertEventField(events[6], key: "resultCategory", equals: .string("action_failed"))
        XCTAssertEventField(events[6], key: "durationMilliseconds", equals: .integer(60))
        XCTAssertEqual(openSpanCount, 0)
    }

    func test_rejectionTelemetryReplacementMatrixFencesOutcomeAfterClosingOriginalSpan() async throws {
        for actionName in ["reminders.create", "calendar.query"] {
            for gatedEvent in [TelemetryEventName.actionProposalRejected, .turnCancelled] {
                for replace in [false, true] {
                    let firstTurnID = TelemetryTurnID("turn-rejection-first")
                    let latestTurnID = TelemetryTurnID("turn-rejection-latest")
                    let host = ApprovalFixtureHost(fixture: .executed)
                    let auditStore = InMemoryAuditStore()
                    let sink = GatedFirstTerminalTelemetrySink(gatedEvent: gatedEvent)
                    let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 3_900, step: 10), sinks: [sink])
                    let session = AssistantSession(
                        generator: SequencedStructuredOutputGenerator(outputs: [.action(name: actionName), .action(name: "reminders.create")]),
                        actionHost: host, auditStore: auditStore, telemetryRecorder: recorder
                    )
                    _ = await session.submitText(AssistantTextRequest(turnID: firstTurnID, text: "Private rejected request."))
                    let pending = await session.pendingProposal()
                    let proposal = try XCTUnwrap(pending)
                    let rejection = Task { try await session.reject(proposal: proposal) }
                    await sink.waitForFirstTerminal()
                    var latestProposal: ActionProposal?
                    if replace {
                        let latestOutcome = await session.submitText(
                            AssistantTextRequest(turnID: latestTurnID, text: "Private latest request.")
                        )
                        let latestPending = await session.pendingProposal()
                        let replacement = try XCTUnwrap(latestPending)
                        latestProposal = replacement
                        XCTAssertEqual(latestOutcome, .proposal(AssistantTurnProposal(
                            turnID: latestTurnID, proposal: replacement, message: replacement.summary
                        )))
                    }
                    await sink.releaseFirstTerminal()
                    let outcome = try await rejection.value
                    let finalPending = await session.pendingProposal()
                    let entries = await auditStore.entries()
                    let executionCount = await host.executionCount()
                    let openSpanCount = await recorder.openSpanCount()
                    let events = await sink.snapshot()
                    let firstEvents = events.filter { $0.turnID == firstTurnID }
                    XCTAssertEqual(outcome, .cancelled(AssistantTurnCancellation(
                        turnID: firstTurnID,
                        message: replace ? "Okay, I moved on to the latest request." : "Okay, I won't do that."
                    )), "\(actionName), \(gatedEvent), replace=\(replace)")
                    XCTAssertEqual(finalPending, latestProposal)
                    XCTAssertEqual(executionCount, 0)
                    XCTAssertTrue(entries.isEmpty)
                    XCTAssertEqual(openSpanCount, replace ? 1 : 0)
                    var expectedEvents: [TelemetryEventName] = [.turnStarted, .inputTextReceived]
                    if actionName == "calendar.query" { expectedEvents += [.actionExecutionStarted, .actionExecutionCancelled] }
                    expectedEvents += [.actionProposalCreated, .actionProposalRejected, .turnCancelled]
                    XCTAssertEventNames(firstEvents, expectedEvents)
                    XCTAssertEventField(try XCTUnwrap(firstEvents.last), key: "resultCategory", equals: .string("rejected"))
                    XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count))
                    XCTAssertNoVisibleRequestContent("Private rejected request.", in: events)
                    XCTAssertNoVisibleRequestContent("Private latest request.", in: events)
                    if let latestProposal {
                        _ = try await session.reject(proposal: latestProposal)
                        let finalOpenSpanCount = await recorder.openSpanCount()
                        XCTAssertEqual(finalOpenSpanCount, 0)
                    }
                }
            }
        }
    }

    func test_reject_clearsPendingProposalWithoutExecutingMutation() async throws {
        let turnID = TelemetryTurnID("turn-reject")
        let request = AssistantTextRequest(turnID: turnID, text: "Delete tomorrow's reminder.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "reminders.delete"))
        let host = FakeActionHost()
        let auditStore = InMemoryAuditStore()
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 4_000, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: host,
            auditStore: auditStore,
            telemetryRecorder: recorder
        )

        _ = await session.submitText(request)
        let pendingProposal = await session.pendingProposal()
        let proposal = try XCTUnwrap(pendingProposal)

        let outcome = try await session.reject(proposal: proposal)
        let pendingAfterRejection = await session.pendingProposal()
        let approvedExecutionCount = await host.approvedExecutionCount()
        let invocationCount = await host.invocationCount()
        let auditEntries = await auditStore.entries()
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .cancelled(AssistantTurnCancellation(turnID: turnID, message: "Okay, I won't do that."))
        )
        XCTAssertNil(pendingAfterRejection)
        XCTAssertEqual(approvedExecutionCount, 0)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(auditEntries.isEmpty)
        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .inputTextReceived,
                .actionProposalCreated,
                .actionProposalRejected,
                .turnCancelled
            ]
        )
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[3], key: "state", equals: .string("proposal_rejected"))
        XCTAssertEventField(events[4], key: "resultCategory", equals: .string("rejected"))
        XCTAssertEventField(events[4], key: "durationMilliseconds", equals: .integer(40))
    }

    func test_submitText_withStructuredOutputValidationFailureProducesClearErrorState() async throws {
        let turnID = TelemetryTurnID("turn-validation-failed")
        let request = AssistantTextRequest(turnID: turnID, text: "Please do something unsupported from noisy ASR text.")
        let generator = ThrowingStructuredOutputGenerator(error: StructuredOutputGenerationError.validationFailed)
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 4_500, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: FakeActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let outcome = await session.submitText(request)
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .failure(
                AssistantTurnFailure(
                    turnID: turnID,
                    message: "Sorry, I couldn't understand that request."
                )
            )
        )
        XCTAssertEventNames(events, [.turnStarted, .inputTextReceived, .turnFailed])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[2], key: "state", equals: .string("failed"))
        XCTAssertEventField(events[2], key: "resultCategory", equals: .string("validation_failed"))
        XCTAssertEventField(events[2], key: "durationMilliseconds", equals: .integer(20))
    }

    func test_submitText_withUnsupportedActionFailsWithClearMessage() async throws {
        let turnID = TelemetryTurnID("turn-invalid")
        let request = AssistantTextRequest(turnID: turnID, text: "Search my mail for invoices.")
        let generator = FakeStructuredOutputGenerator(output: .action(name: "mail.search"))
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 5_000, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: FakeActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let outcome = await session.submitText(request)
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .failure(
                AssistantTurnFailure(
                    turnID: turnID,
                    message: "Sorry, Ora v2 does not support that action."
                )
            )
        )
        XCTAssertEventNames(events, [.turnStarted, .inputTextReceived, .turnFailed])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[2], key: "state", equals: .string("failed"))
        XCTAssertEventField(events[2], key: "resultCategory", equals: .string("unsupported_action"))
        XCTAssertNoEventField(events[2], key: "actionName")
        XCTAssertEventField(events[2], key: "durationMilliseconds", equals: .integer(20))
    }

    func test_submitText_withUnsupportedActionContainingRequestTextDoesNotLogRawActionName() async throws {
        let turnID = TelemetryTurnID("turn-sensitive-invalid")
        let request = AssistantTextRequest(turnID: turnID, text: "Search mail for private invoice details")
        let generator = FakeStructuredOutputGenerator(output: .action(name: request.text))
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: TestTelemetryClock(start: 5_500, step: 10), sinks: [sink])
        let session = AssistantSession(
            generator: generator,
            actionHost: FakeActionHost(),
            auditStore: InMemoryAuditStore(),
            telemetryRecorder: recorder
        )

        let outcome = await session.submitText(request)
        let events = await sink.snapshot()

        XCTAssertEqual(
            outcome,
            .failure(
                AssistantTurnFailure(
                    turnID: turnID,
                    message: "Sorry, Ora v2 does not support that action."
                )
            )
        )
        XCTAssertEventNames(events, [.turnStarted, .inputTextReceived, .turnFailed])
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertNoEventField(events[2], key: "actionName")
        XCTAssertEventField(events[2], key: "resultCategory", equals: .string("unsupported_action"))
    }
}

private enum HostCallbackFixture: CaseIterable, Sendable {
    case mutationProposal, readProposal, readExecuted

    var actionName: String { self == .mutationProposal ? "reminders.create" : "calendar.query" }
}

private struct CallbackIdentityHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default
    let callback: HostCallbackFixture
    let mismatched: Bool

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let requested = self.catalog.action(named: name) else { throw ActionHostError.unsupportedAction(name) }
        let returned = self.mismatched
            ? Action(name: "Private unvetted returned action.", domain: .system, kind: requested.kind)
            : requested
        if self.callback == .readExecuted { return .executed(action: returned, summary: "Matched read result.") }
        return .proposed(ActionProposal(action: returned))
    }
}

private enum ApprovalGate: Equatable {
    case event(TelemetryEventName)
    case host
    case audit

    var eventName: TelemetryEventName? {
        if case .event(let name) = self { return name }
        return nil
    }
}

private enum ApprovalResultFixture: Sendable {
    case executed, thrown, proposed, wrongKind, wrongName, wrongDomain

    var reportsExecution: Bool { self != .thrown && self != .proposed }
    var isMismatch: Bool { self == .wrongKind || self == .wrongName || self == .wrongDomain }

    func eventNames(for action: Action) -> [TelemetryEventName] {
        var names: [TelemetryEventName] = [.turnStarted, .inputTextReceived]
        if action.kind == .read { names += [.actionExecutionStarted, .actionExecutionCancelled] }
        names += [.actionProposalCreated, .actionProposalApproved, .actionExecutionStarted]
        if self == .executed {
            names.append(.actionExecutionCompleted)
            if action.kind == .mutation { names.append(.auditEntryRecorded) }
            names.append(.turnCompleted)
        } else {
            if self.isMismatch && action.kind == .mutation { names.append(.auditEntryRecorded) }
            names += [.actionExecutionFailed, .turnFailed]
        }
        return names
    }
}

private actor ApprovalFixtureHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default
    private let fixture: ApprovalResultFixture
    private let gateExecution: Bool
    private var count = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(fixture: ApprovalResultFixture, gateExecution: Bool = false) {
        self.fixture = fixture
        self.gateExecution = gateExecution
    }

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else { throw ActionHostError.unsupportedAction(name) }
        guard approval != nil else { return .proposed(ActionProposal(action: action)) }
        self.count += 1
        if self.gateExecution {
            self.startedContinuation?.resume()
            self.startedContinuation = nil
            await withCheckedContinuation { self.releaseContinuation = $0 }
        }
        switch self.fixture {
        case .thrown: throw FailureFixtureError.privateDetails
        case .proposed: return .proposed(ActionProposal(action: action))
        case .executed: return .executed(action: action, summary: "Private execution summary.")
        case .wrongKind:
            return .executed(action: Action(name: action.name, domain: action.domain, kind: action.kind == .mutation ? .read : .mutation), summary: "Private execution summary.")
        case .wrongName:
            return .executed(action: Action(name: "Private unvetted returned action.", domain: action.domain, kind: action.kind), summary: "Private execution summary.")
        case .wrongDomain:
            return .executed(action: Action(name: action.name, domain: .system, kind: action.kind), summary: "Private execution summary.")
        }
    }

    func waitForExecution() async {
        if self.count > 0 { return }
        await withCheckedContinuation { self.startedContinuation = $0 }
    }

    func releaseExecution() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    func executionCount() -> Int { self.count }
}

private actor GatedApprovalAuditStore: AuditStoring {
    private let gateRecord: Bool
    private var storedEntries: [AuditEntry] = []
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(gateRecord: Bool) { self.gateRecord = gateRecord }

    func record(_ entry: AuditEntry) async {
        self.storedEntries.append(entry)
        if self.gateRecord {
            self.startedContinuation?.resume()
            self.startedContinuation = nil
            await withCheckedContinuation { self.releaseContinuation = $0 }
        }
    }

    func waitForRecord() async {
        if !self.storedEntries.isEmpty { return }
        await withCheckedContinuation { self.startedContinuation = $0 }
    }

    func releaseRecord() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    func entries() async -> [AuditEntry] { self.storedEntries }
}

private enum SubmitFailureFixture: String, CaseIterable {
    case validation = "validation_failed"
    case generation = "generation_failed"
    case unsupported = "unsupported_action"
    case action = "action_failed"
    case proposal = "proposal_failed"
    case unsafeMutation = "mutation_executed_without_approval"

    var action: Action? {
        switch self {
        case .action:
            return ActionCatalog.v2Default.action(named: "calendar.query")
        case .proposal, .unsafeMutation:
            return ActionCatalog.v2Default.action(named: "reminders.create")
        default:
            return nil
        }
    }

    var host: any ActionHosting {
        switch self {
        case .action, .proposal:
            return ThrowingUnapprovedActionHost()
        case .unsafeMutation:
            return UnsafeMutationActionHost()
        default:
            return FakeActionHost()
        }
    }

    var message: String {
        switch self {
        case .validation:
            return "Sorry, I couldn't understand that request."
        case .generation, .action:
            return "Sorry, I couldn't complete that request."
        case .unsupported:
            return "Sorry, Ora v2 does not support that action."
        case .proposal:
            return "Sorry, I couldn't prepare that action for confirmation."
        case .unsafeMutation:
            return "Sorry, that action needs confirmation before I can run it."
        }
    }

    var eventNames: [TelemetryEventName] {
        if self == .action {
            return [.turnStarted, .inputTextReceived, .actionExecutionStarted, .actionExecutionFailed, .turnFailed]
        }
        return [.turnStarted, .inputTextReceived, .turnFailed]
    }
}

private enum FailureFixtureError: LocalizedError, Sendable {
    case privateDetails

    var errorDescription: String? { "Private fixture failure." }
}

private actor FailureFixtureGenerator: StructuredOutputGenerating {
    private let fixture: SubmitFailureFixture
    private let failingTurnID: TelemetryTurnID

    init(fixture: SubmitFailureFixture, failingTurnID: TelemetryTurnID) {
        self.fixture = fixture
        self.failingTurnID = failingTurnID
    }

    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        guard request.turnID == self.failingTurnID else {
            return .response(message: "Latest response.")
        }
        switch self.fixture {
        case .validation:
            throw StructuredOutputGenerationError.validationFailed
        case .generation:
            throw FailureFixtureError.privateDetails
        case .unsupported:
            return .action(name: "Private unsupported output.")
        case .action:
            return .action(name: "calendar.query")
        case .proposal, .unsafeMutation:
            return .action(name: "reminders.create")
        }
    }
}

private struct ThrowingUnapprovedActionHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        throw FailureFixtureError.privateDetails
    }
}

private actor CountingResponseGenerator: StructuredOutputGenerating {
    private var calls: [TelemetryTurnID] = []

    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        self.calls.append(request.turnID)
        return .response(message: "Latest response.")
    }

    func callCount(for turnID: TelemetryTurnID) -> Int {
        self.calls.filter { $0 == turnID }.count
    }
}

private actor FakeStructuredOutputGenerator: StructuredOutputGenerating {
    private let output: StructuredAssistantOutput

    init(output: StructuredAssistantOutput) {
        self.output = output
    }

    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        self.output
    }
}

private actor SequencedStructuredOutputGenerator: StructuredOutputGenerating {
    private var outputs: [StructuredAssistantOutput]

    init(outputs: [StructuredAssistantOutput]) {
        self.outputs = outputs
    }

    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        self.outputs.removeFirst()
    }
}

private actor GatedFirstStructuredOutputGenerator: StructuredOutputGenerating {
    private let immediateOutputAfterFirst: StructuredAssistantOutput
    private var requestCount = 0
    private var firstRequestStarted = false
    private var firstRequestStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstRequestReleaseContinuation: CheckedContinuation<StructuredAssistantOutput, Never>?

    init(immediateOutputAfterFirst: StructuredAssistantOutput) {
        self.immediateOutputAfterFirst = immediateOutputAfterFirst
    }

    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        self.requestCount += 1
        if self.requestCount == 1 {
            self.firstRequestStarted = true
            self.firstRequestStartedContinuation?.resume()
            self.firstRequestStartedContinuation = nil
            return await withCheckedContinuation { continuation in
                self.firstRequestReleaseContinuation = continuation
            }
        }
        return self.immediateOutputAfterFirst
    }

    func waitForFirstRequest() async {
        if self.firstRequestStarted {
            return
        }
        await withCheckedContinuation { continuation in
            self.firstRequestStartedContinuation = continuation
        }
    }

    func releaseFirstRequest(with output: StructuredAssistantOutput) {
        self.firstRequestReleaseContinuation?.resume(returning: output)
        self.firstRequestReleaseContinuation = nil
    }
}

private actor ThrowingStructuredOutputGenerator: StructuredOutputGenerating {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput {
        throw self.error
    }
}

private actor FakeActionHost: ActionHosting {
    struct Invocation: Sendable, Equatable {
        let actionName: String
        let approval: ActionApproval?
    }

    let catalog: ActionCatalog
    private var invocations: [Invocation] = []

    init(catalog: ActionCatalog = .v2Default) {
        self.catalog = catalog
    }

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        self.invocations.append(Invocation(actionName: name, approval: approval))

        guard let action = self.catalog.action(named: name) else {
            throw ActionHostError.unsupportedAction(name)
        }

        switch action.name {
        case "calendar.query":
            return .executed(action: action, summary: "Found 3 events for today.")
        case "reminders.create":
            let expectedProposal = ActionProposal(
                action: action,
                summary: "Create reminder: Send the report?",
                confirmationLabel: "Create reminder"
            )
            if case .approved? = approval {
                return .executed(action: action, summary: "Created reminder: Send the report.")
            }
            return .proposed(expectedProposal)
        case "reminders.delete":
            if case .approved? = approval {
                return .executed(action: action, summary: "Deleted reminder.")
            }
            return .proposed(ActionProposal(action: action, summary: "Delete reminder?", confirmationLabel: "Delete reminder"))
        default:
            if action.requiresConfirmation {
                if case .approved? = approval {
                    return .executed(action: action, summary: "\(action.name) executed.")
                }
                return .proposed(ActionProposal(action: action))
            }
            return .executed(action: action, summary: "\(action.name) executed.")
        }
    }

    func approvedExecutionCount() -> Int {
        self.invocations.filter { $0.approval != nil }.count
    }

    func readExecutionCount() -> Int {
        self.invocations.filter {
            $0.approval == nil && self.catalog.action(named: $0.actionName)?.requiresConfirmation == false
        }.count
    }

    func invocationCount() -> Int {
        self.invocations.count
    }
}

enum TestActionHostError: Error, Sendable, Equatable {
    case approvedExecutionFailed
}

private actor UnsafeMutationActionHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else {
            throw ActionHostError.unsupportedAction(name)
        }
        return .executed(action: action, summary: "Unsafe pre-approval execution.")
    }
}

private actor ThrowingApprovedActionHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else {
            throw ActionHostError.unsupportedAction(name)
        }
        if case .approved? = approval {
            throw TestActionHostError.approvedExecutionFailed
        }
        if action.requiresConfirmation {
            return .proposed(ActionProposal(action: action))
        }
        return .executed(action: action, summary: "\(action.name) executed.")
    }
}

private actor GatedFirstTerminalTelemetrySink: TelemetrySink {
    private let gatedEvent: TelemetryEventName
    private var skipFirstMatches: Int
    private var events: [TelemetryEvent] = []
    private var firstTerminalStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(gatedEvent: TelemetryEventName, skipFirstMatches: Int = 0) {
        self.gatedEvent = gatedEvent
        self.skipFirstMatches = skipFirstMatches
    }

    func record(_ event: TelemetryEvent) async {
        self.events.append(event)
        if event.name == self.gatedEvent, !self.firstTerminalStarted {
            if self.skipFirstMatches > 0 {
                self.skipFirstMatches -= 1
                return
            }
            self.firstTerminalStarted = true
            self.startedContinuation?.resume()
            self.startedContinuation = nil
            await withCheckedContinuation { continuation in
                self.releaseContinuation = continuation
            }
        }
    }

    func waitForFirstTerminal() async {
        if self.firstTerminalStarted {
            return
        }
        await withCheckedContinuation { continuation in
            self.startedContinuation = continuation
        }
    }

    func releaseFirstTerminal() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    func snapshot() -> [TelemetryEvent] {
        self.events
    }
}

private actor GatedFirstProposalTelemetrySink: TelemetrySink {
    private var events: [TelemetryEvent] = []
    private var firstProposalRecordStarted = false
    private var firstProposalRecordContinuation: CheckedContinuation<Void, Never>?
    private var releaseFirstProposalContinuation: CheckedContinuation<Void, Never>?

    func record(_ event: TelemetryEvent) async {
        self.events.append(event)
        if event.name == .actionProposalCreated, !self.firstProposalRecordStarted {
            self.firstProposalRecordStarted = true
            self.firstProposalRecordContinuation?.resume()
            self.firstProposalRecordContinuation = nil
            await withCheckedContinuation { continuation in
                self.releaseFirstProposalContinuation = continuation
            }
        }
    }

    func waitForFirstProposalRecord() async {
        if self.firstProposalRecordStarted {
            return
        }
        await withCheckedContinuation { continuation in
            self.firstProposalRecordContinuation = continuation
        }
    }

    func releaseFirstProposalRecord() {
        self.releaseFirstProposalContinuation?.resume()
        self.releaseFirstProposalContinuation = nil
    }

    func snapshot() -> [TelemetryEvent] {
        self.events
    }
}

private actor GatedFirstActionCancellationTelemetrySink: TelemetrySink {
    private var events: [TelemetryEvent] = []
    private var firstActionCancellationStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func record(_ event: TelemetryEvent) async {
        self.events.append(event)
        if event.name == .actionExecutionCancelled, !self.firstActionCancellationStarted {
            self.firstActionCancellationStarted = true
            self.startedContinuation?.resume()
            self.startedContinuation = nil
            await withCheckedContinuation { continuation in
                self.releaseContinuation = continuation
            }
        }
    }

    func waitForFirstActionCancellation() async {
        if self.firstActionCancellationStarted {
            return
        }
        await withCheckedContinuation { continuation in
            self.startedContinuation = continuation
        }
    }

    func releaseFirstActionCancellation() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    func snapshot() -> [TelemetryEvent] {
        self.events
    }
}

private actor ReadProposalActionHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default
    private var approvedInvocations: Int = 0

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else {
            throw ActionHostError.unsupportedAction(name)
        }
        if case .approved? = approval {
            self.approvedInvocations += 1
            return .executed(action: action, summary: "Approved read proposal.")
        }
        return .proposed(ActionProposal(
            action: action,
            summary: "Allow calendar lookup?",
            confirmationLabel: "Allow"
        ))
    }

    func approvedExecutionCount() -> Int {
        self.approvedInvocations
    }
}

private actor GatedReadActionHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default
    private var readExecutionStarted = false
    private var readExecutionStartedContinuation: CheckedContinuation<Void, Never>?
    private var releaseReadExecutionContinuation: CheckedContinuation<Void, Never>?

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else {
            throw ActionHostError.unsupportedAction(name)
        }
        if name == "calendar.query", approval == nil {
            self.readExecutionStarted = true
            self.readExecutionStartedContinuation?.resume()
            self.readExecutionStartedContinuation = nil
            await withCheckedContinuation { continuation in
                self.releaseReadExecutionContinuation = continuation
            }
            return .executed(action: action, summary: "Found 3 events for today.")
        }
        if action.requiresConfirmation {
            if case .approved? = approval {
                return .executed(action: action, summary: "\(action.name) executed.")
            }
            return .proposed(ActionProposal(action: action))
        }
        return .executed(action: action, summary: "\(action.name) executed.")
    }

    func waitForReadExecution() async {
        if self.readExecutionStarted {
            return
        }
        await withCheckedContinuation { continuation in
            self.readExecutionStartedContinuation = continuation
        }
    }

    func releaseReadExecution() {
        self.releaseReadExecutionContinuation?.resume()
        self.releaseReadExecutionContinuation = nil
    }
}

private actor GatedActionHost: ActionHosting {
    let catalog: ActionCatalog = .v2Default
    private var approvedInvocations: Int = 0
    private var firstApprovedExecutionStarted = false
    private var firstApprovedExecutionStartedContinuation: CheckedContinuation<Void, Never>?
    private var releaseFirstApprovedExecutionContinuation: CheckedContinuation<Void, Never>?

    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else {
            throw ActionHostError.unsupportedAction(name)
        }

        if case .approved? = approval {
            self.approvedInvocations += 1
            if self.approvedInvocations == 1 {
                self.firstApprovedExecutionStarted = true
                self.firstApprovedExecutionStartedContinuation?.resume()
                self.firstApprovedExecutionStartedContinuation = nil
                await withCheckedContinuation { continuation in
                    self.releaseFirstApprovedExecutionContinuation = continuation
                }
            }
            return .executed(action: action, summary: "Created reminder: Send the report.")
        }

        if action.requiresConfirmation {
            return .proposed(ActionProposal(action: action))
        }
        return .executed(action: action, summary: "\(action.name) executed.")
    }

    func waitForFirstApprovedExecution() async {
        if self.firstApprovedExecutionStarted {
            return
        }
        await withCheckedContinuation { continuation in
            self.firstApprovedExecutionStartedContinuation = continuation
        }
    }

    func releaseFirstApprovedExecution() {
        self.releaseFirstApprovedExecutionContinuation?.resume()
        self.releaseFirstApprovedExecutionContinuation = nil
    }

    func approvedExecutionCount() -> Int {
        self.approvedInvocations
    }
}

private func XCTAssertTurnMetadata(
    _ events: [TelemetryEvent],
    turnID: TelemetryTurnID,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(events.map(\.turnID), Array(repeating: turnID, count: events.count), file: file, line: line)
    XCTAssertEqual(events.map(\.sequenceNumber), Array(1...events.count), file: file, line: line)
}

private func XCTAssertNoVisibleRequestContent(
    _ text: String,
    in events: [TelemetryEvent],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let forbiddenKeys: Set<String> = ["text", "transcript", "prompt", "rawPrompt"]

    for event in events {
        XCTAssertFalse(event.fields.contains { forbiddenKeys.contains($0.key) }, file: file, line: line)
        XCTAssertFalse(event.fields.contains {
            guard case .string(let value) = $0.value else { return false }
            return value == text
        }, file: file, line: line)
        XCTAssertFalse(OSTelemetrySink.render(event).message.contains(text), file: file, line: line)
    }
}

private func XCTAssertEventField(
    _ event: TelemetryEvent,
    key: String,
    equals expectedValue: TelemetryFieldValue,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let field = event.fields.first { $0.key == key }
    XCTAssertEqual(field?.value, expectedValue, file: file, line: line)
    XCTAssertEqual(field?.visibility, .publicDebug, file: file, line: line)
}

private func XCTAssertNoEventField(
    _ event: TelemetryEvent,
    key: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(event.fields.contains { $0.key == key }, file: file, line: line)
}
