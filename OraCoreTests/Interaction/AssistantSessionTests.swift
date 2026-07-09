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
        XCTAssertEqual(approvedExecutionCount, 0)
        XCTAssertEqual(readExecutionCount, 0)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEventNames(events, [.turnStarted, .inputTextReceived, .actionProposalCreated])
        XCTAssertTurnMetadata(events, turnID: turnID)
        XCTAssertNoVisibleRequestContent(request.text, in: events)
        XCTAssertEventField(events[2], key: "phase", equals: .string("action"))
        XCTAssertEventField(events[2], key: "state", equals: .string("proposal_created"))
        XCTAssertEventField(events[2], key: "actionName", equals: .string("reminders.create"))
        XCTAssertEqual(openSpanCount, 1)
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
        XCTAssertEqual(proposal.proposalID, "turn-default-host-approve:calendar.create")

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
        XCTAssertEqual(pendingAfterFirstCompletion.proposalID, "turn-overlap-second:reminders.create")
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
        XCTAssertEqual(invocationCount, 0)
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
