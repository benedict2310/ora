import Foundation

enum AssistantSessionError: Error, Sendable, Equatable {
    case noPendingProposal
    case proposalMismatch(expected: ActionProposal, received: ActionProposal)
    case executedActionMismatch(expected: Action, received: Action)
}

actor AssistantSession {
    private struct PendingProposalState: Sendable, Equatable {
        let turnID: TelemetryTurnID
        let turnSpan: TelemetrySpanToken
        let turnGeneration: Int
        let proposal: ActionProposal
    }

    // Facts reported by the host are classified before checking UI eligibility.
    // Cancellation is a signal, not a guarantee that an effect was rolled back.
    private enum OperationFact {
        case executed(String)
        case proposed(ActionProposal)
        case failed(category: String, message: String)
        case cancelled
        case unapprovedExecution(metadataMatches: Bool)
    }

    private let generator: any StructuredOutputGenerating
    private let actionHost: any ActionHosting
    private let auditStore: any AuditStoring
    private let telemetryRecorder: TelemetryRecorder
    private var pendingProposalState: PendingProposalState?
    private var nextTextTurnGeneration: Int = 1
    private var currentTextTurnGeneration: Int?

    init(
        generator: any StructuredOutputGenerating,
        actionHost: any ActionHosting,
        auditStore: any AuditStoring,
        telemetryRecorder: TelemetryRecorder
    ) {
        self.generator = generator
        self.actionHost = actionHost
        self.auditStore = auditStore
        self.telemetryRecorder = telemetryRecorder
    }

    func submitText(_ request: AssistantTextRequest) async -> AssistantTurnOutcome {
        let turnGeneration = self.beginTextTurn()
        await self.cancelPendingProposalForReplacementIfNeeded()
        let turnSpan = await self.telemetryRecorder.beginSpan(
            .turn, turnID: request.turnID,
            fields: self.baseFields(phase: "turn", state: "started")
        )
        _ = await self.telemetryRecorder.record(
            .inputTextReceived, turnID: request.turnID,
            fields: self.baseFields(phase: "input", state: "received") + [
                self.intField("characterCount", request.text.count)
            ]
        )
        guard self.canPresentOrdinaryTurn(turnGeneration) else {
            return await self.cancelOrdinaryTurn(turnID: request.turnID, turnSpan: turnSpan, turnGeneration: turnGeneration)
        }
        do {
            try Task.checkCancellation()
            let output = try await self.generator.generate(for: request)
            try Task.checkCancellation()
            guard self.canPresentOrdinaryTurn(turnGeneration) else {
                return await self.cancelOrdinaryTurn(turnID: request.turnID, turnSpan: turnSpan, turnGeneration: turnGeneration)
            }
            switch output {
            case .response(let message):
                return await self.completeOrdinaryTurn(
                    turnID: request.turnID, turnSpan: turnSpan, turnGeneration: turnGeneration,
                    message: message, resultCategory: "response"
                )
            case .action(let name):
                guard let action = self.actionHost.catalog.action(named: name) else {
                    return await self.failTurn(
                        turnID: request.turnID, turnSpan: turnSpan,
                        message: "Sorry, Ora v2 does not support that action.", resultCategory: "unsupported_action",
                        turnGeneration: turnGeneration
                    )
                }
                return await self.executeUnapprovedAction(
                    action: action, turnID: request.turnID, turnSpan: turnSpan, turnGeneration: turnGeneration
                )
            }
        } catch is CancellationError {
            return await self.cancelOrdinaryTurn(turnID: request.turnID, turnSpan: turnSpan, turnGeneration: turnGeneration)
        } catch StructuredOutputGenerationError.validationFailed {
            return await self.failTurn(
                turnID: request.turnID, turnSpan: turnSpan,
                message: "Sorry, I couldn't understand that request.", resultCategory: "validation_failed",
                turnGeneration: turnGeneration
            )
        } catch {
            return await self.failTurn(
                turnID: request.turnID, turnSpan: turnSpan,
                message: "Sorry, I couldn't complete that request.", resultCategory: "generation_failed",
                turnGeneration: turnGeneration
            )
        }
    }

    func approve(proposal: ActionProposal) async throws -> AssistantTurnOutcome {
        let pending = try self.requirePendingProposal(matching: proposal)
        let approvedAction = pending.proposal.action
        self.pendingProposalState = nil

        _ = await self.telemetryRecorder.record(
            .actionProposalApproved,
            turnID: pending.turnID,
            fields: self.actionFields(approvedAction, state: "proposal_approved")
        )

        let actionSpan = await self.telemetryRecorder.beginSpan(
            .actionExecution,
            turnID: pending.turnID,
            fields: self.actionFields(approvedAction, state: "execution_started")
        )

        let result: ActionResult
        do {
            result = try await self.actionHost.execute(
                actionNamed: approvedAction.name,
                approval: .approved(proposal)
            )
        } catch {
            await self.failApprovedAction(
                actionSpan: actionSpan,
                turnSpan: pending.turnSpan,
                action: approvedAction,
                resultCategory: "action_failed"
            )
            guard self.isCurrentTextTurn(pending.turnGeneration) else {
                return self.staleTurnCancellation(turnID: pending.turnID)
            }
            throw error
        }

        switch result {
        case .executed(let returnedAction, let summary):
            let metadataMatches = returnedAction == approvedAction
            if approvedAction.kind == .mutation {
                let auditEntry = AuditEntry(
                    turnID: pending.turnID,
                    actionName: approvedAction.name,
                    actionDomain: approvedAction.domain,
                    actionKind: approvedAction.kind,
                    summary: metadataMatches ? summary : "Approved mutation reported execution, but Ora could not verify the returned action metadata."
                )
                await self.auditStore.record(auditEntry)
            }

            guard metadataMatches else {
                if approvedAction.kind == .mutation {
                    await self.recordAuditTelemetry(action: approvedAction, turnID: pending.turnID)
                }
                await self.failApprovedAction(
                    actionSpan: actionSpan,
                    turnSpan: pending.turnSpan,
                    action: approvedAction,
                    resultCategory: "action_mismatch"
                )
                guard self.isCurrentTextTurn(pending.turnGeneration) else {
                    return self.staleTurnCancellation(turnID: pending.turnID)
                }
                throw AssistantSessionError.executedActionMismatch(expected: approvedAction, received: returnedAction)
            }
            _ = try? await self.telemetryRecorder.endSpan(
                actionSpan,
                fields: self.actionFields(approvedAction, state: "completed") + [
                    self.stringField("resultCategory", "executed")
                ]
            )
            if approvedAction.kind == .mutation {
                await self.recordAuditTelemetry(action: approvedAction, turnID: pending.turnID)
            }
            _ = try? await self.telemetryRecorder.endSpan(
                pending.turnSpan,
                fields: self.baseFields(phase: "turn", state: "completed") + [
                    self.stringField("resultCategory", "executed")
                ]
            )
            guard self.isCurrentTextTurn(pending.turnGeneration) else {
                return self.staleTurnCancellation(turnID: pending.turnID)
            }
            return .result(AssistantTurnResult(turnID: pending.turnID, message: summary))
        case .proposed(let returnedProposal):
            await self.failApprovedAction(
                actionSpan: actionSpan,
                turnSpan: pending.turnSpan,
                action: approvedAction,
                resultCategory: "unexpected_proposal"
            )
            guard self.isCurrentTextTurn(pending.turnGeneration) else {
                return self.staleTurnCancellation(turnID: pending.turnID)
            }
            throw AssistantSessionError.proposalMismatch(expected: pending.proposal, received: returnedProposal)
        }
    }

    func reject(proposal: ActionProposal) async throws -> AssistantTurnOutcome {
        let pending = try self.requirePendingProposal(matching: proposal)
        self.pendingProposalState = nil

        _ = await self.telemetryRecorder.record(
            .actionProposalRejected,
            turnID: pending.turnID,
            fields: self.actionFields(proposal.action, state: "proposal_rejected")
        )
        _ = try? await self.telemetryRecorder.cancelSpan(
            pending.turnSpan,
            fields: self.baseFields(phase: "turn", state: "cancelled") + [
                self.stringField("resultCategory", "rejected")
            ]
        )

        guard self.isCurrentTextTurn(pending.turnGeneration) else {
            return self.staleTurnCancellation(turnID: pending.turnID)
        }
        return .cancelled(
            AssistantTurnCancellation(
                turnID: pending.turnID,
                message: "Okay, I won't do that."
            )
        )
    }

    func pendingProposal() -> ActionProposal? {
        self.pendingProposalState?.proposal
    }

    private func executeUnapprovedAction(
        action: Action,
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        turnGeneration: Int
    ) async -> AssistantTurnOutcome {
        // This span measures the host attempt, including proposal preparation, not
        // an assertion that a mutation has executed before confirmation.
        let actionSpan = await self.telemetryRecorder.beginSpan(
            .actionExecution, turnID: turnID,
            fields: self.actionFields(action, state: "execution_started")
        )
        guard self.canPresentOrdinaryTurn(turnGeneration) else {
            _ = try? await self.telemetryRecorder.cancelSpan(
                actionSpan, fields: self.actionFields(action, state: "cancelled") + [
                    self.stringField("resultCategory", self.abandonmentCategory(turnGeneration))
                ]
            )
            return await self.cancelOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action)
        }

        let fact: OperationFact
        do {
            let result = try await self.actionHost.execute(actionNamed: action.name, approval: nil)
            switch result {
            case .executed(let returnedAction, let summary):
                if action.requiresConfirmation {
                    fact = .unapprovedExecution(metadataMatches: returnedAction == action)
                } else if returnedAction == action {
                    fact = .executed(summary)
                } else {
                    fact = .failed(category: "action_mismatch", message: "Sorry, I couldn't complete that request.")
                }
            case .proposed(let proposal):
                if proposal.action == action {
                    fact = .proposed(proposal)
                } else {
                    fact = .failed(category: "proposal_action_mismatch", message: "Sorry, I couldn't verify that action.")
                }
            }
        } catch is CancellationError {
            fact = .cancelled
        } catch {
            fact = .failed(
                category: action.requiresConfirmation ? "proposal_failed" : "action_failed",
                message: action.requiresConfirmation ? "Sorry, I couldn't prepare that action for confirmation." : "Sorry, I couldn't complete that request."
            )
        }

        // Commit exactly one operation terminal from the fact, regardless of the
        // originating turn's generation or task cancellation state.
        switch fact {
        case .executed:
            _ = try? await self.telemetryRecorder.endSpan(actionSpan, fields: self.actionFields(action, state: "completed") + [self.stringField("resultCategory", "executed")])
        case .proposed:
            _ = try? await self.telemetryRecorder.cancelSpan(actionSpan, fields: self.actionFields(action, state: "cancelled"))
        case .failed(let category, _):
            _ = try? await self.telemetryRecorder.failSpan(actionSpan, fields: self.actionFields(action, state: "failed") + [self.stringField("resultCategory", category)])
        case .cancelled:
            _ = try? await self.telemetryRecorder.cancelSpan(actionSpan, fields: self.actionFields(action, state: "cancelled") + [self.stringField("resultCategory", "task_cancelled")])
        case .unapprovedExecution(let metadataMatches):
            let fields = self.actionFields(action, state: metadataMatches ? "completed" : "failed") + [self.stringField("resultCategory", "mutation_executed_without_approval")]
            if metadataMatches {
                _ = try? await self.telemetryRecorder.endSpan(actionSpan, level: .error, fields: fields)
            } else {
                _ = try? await self.telemetryRecorder.failSpan(actionSpan, fields: fields)
            }
        }

        guard self.canPresentOrdinaryTurn(turnGeneration) else {
            return await self.cancelOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action)
        }
        switch fact {
        case .executed(let summary):
            return await self.completeOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, message: summary, resultCategory: "executed")
        case .proposed(let hostProposal):
            return await self.publishProposal(hostProposal, action: action, turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration)
        case .failed(let category, let message):
            return await self.failTurn(turnID: turnID, turnSpan: turnSpan, message: message, resultCategory: category, turnGeneration: turnGeneration, action: action)
        case .cancelled:
            return await self.cancelOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action)
        case .unapprovedExecution:
            return await self.failTurn(
                turnID: turnID, turnSpan: turnSpan, message: "Sorry, that action needs confirmation before I can run it.",
                resultCategory: "mutation_executed_without_approval", turnGeneration: turnGeneration, action: action
            )
        }
    }

    private func publishProposal(
        _ hostProposal: ActionProposal,
        action: Action,
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        turnGeneration: Int
    ) async -> AssistantTurnOutcome {
        guard self.canPresentOrdinaryTurn(turnGeneration) else {
            return await self.cancelOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action)
        }
        let proposal = hostProposal.withProposalID(UUID().uuidString)
        let pending = PendingProposalState(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, proposal: proposal)
        self.pendingProposalState = pending
        _ = await self.telemetryRecorder.record(.actionProposalCreated, turnID: turnID, fields: self.actionFields(action, state: "proposal_created"))
        guard self.pendingProposalState == pending else {
            // A replacement or accepted approval now owns closure of this turn.
            return self.staleTurnCancellation(turnID: turnID)
        }
        guard self.canPresentOrdinaryTurn(turnGeneration) else {
            self.pendingProposalState = nil
            return await self.cancelOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action)
        }
        return .proposal(AssistantTurnProposal(turnID: turnID, proposal: proposal, message: proposal.summary))
    }

    private func completeOrdinaryTurn(
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        turnGeneration: Int,
        message: String,
        resultCategory: String
    ) async -> AssistantTurnOutcome {
        guard self.canPresentOrdinaryTurn(turnGeneration) else {
            return await self.cancelOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration)
        }
        _ = try? await self.telemetryRecorder.endSpan(turnSpan, fields: self.baseFields(phase: "turn", state: "completed") + [self.stringField("resultCategory", resultCategory)])
        guard self.canPresentOrdinaryTurn(turnGeneration) else { return self.quietCancellation(turnID: turnID, turnGeneration: turnGeneration) }
        return .result(AssistantTurnResult(turnID: turnID, message: message))
    }

    private func failTurn(
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        message: String,
        resultCategory: String,
        turnGeneration: Int,
        action: Action? = nil
    ) async -> AssistantTurnOutcome {
        guard self.canPresentOrdinaryTurn(turnGeneration) else {
            return await self.cancelOrdinaryTurn(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action)
        }
        var fields = self.baseFields(phase: "turn", state: "failed") + [self.stringField("resultCategory", resultCategory)]
        if let action { fields += self.actionIdentityFields(action) }
        _ = try? await self.telemetryRecorder.failSpan(turnSpan, fields: fields)
        guard self.canPresentOrdinaryTurn(turnGeneration) else { return self.quietCancellation(turnID: turnID, turnGeneration: turnGeneration) }
        return .failure(AssistantTurnFailure(turnID: turnID, message: message))
    }

    private func cancelOrdinaryTurn(
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        turnGeneration: Int,
        action: Action? = nil
    ) async -> AssistantTurnOutcome {
        var fields = self.baseFields(phase: "turn", state: "cancelled") + [self.stringField("resultCategory", self.abandonmentCategory(turnGeneration))]
        if let action { fields += self.actionIdentityFields(action) }
        _ = try? await self.telemetryRecorder.cancelSpan(turnSpan, fields: fields)
        return self.quietCancellation(turnID: turnID, turnGeneration: turnGeneration)
    }

    private func canPresentOrdinaryTurn(_ generation: Int) -> Bool {
        self.isCurrentTextTurn(generation) && !Task.isCancelled
    }

    private func abandonmentCategory(_ generation: Int) -> String {
        self.isCurrentTextTurn(generation) ? "task_cancelled" : "replaced"
    }

    private func quietCancellation(turnID: TelemetryTurnID, turnGeneration: Int) -> AssistantTurnOutcome {
        guard self.isCurrentTextTurn(turnGeneration) else { return self.staleTurnCancellation(turnID: turnID) }
        return .cancelled(AssistantTurnCancellation(turnID: turnID, message: "Okay, I cancelled that request."))
    }

    private func recordAuditTelemetry(action: Action, turnID: TelemetryTurnID) async {
        _ = await self.telemetryRecorder.record(
            .auditEntryRecorded, turnID: turnID,
            fields: self.baseFields(phase: "audit", state: "recorded") + self.actionIdentityFields(action) + [self.intField("count", 1)]
        )
    }

    private func beginTextTurn() -> Int {
        let generation = self.nextTextTurnGeneration
        self.nextTextTurnGeneration += 1
        self.currentTextTurnGeneration = generation
        return generation
    }

    private func isCurrentTextTurn(_ generation: Int) -> Bool {
        self.currentTextTurnGeneration == generation
    }

    private func cancelPendingProposalForReplacementIfNeeded() async {
        guard let pending = self.pendingProposalState else { return }
        self.pendingProposalState = nil
        _ = try? await self.telemetryRecorder.cancelSpan(pending.turnSpan, fields: self.baseFields(phase: "turn", state: "cancelled") + [self.stringField("resultCategory", "replaced")])
    }

    private func staleTurnCancellation(turnID: TelemetryTurnID) -> AssistantTurnOutcome {
        .cancelled(AssistantTurnCancellation(turnID: turnID, message: "Okay, I moved on to the latest request."))
    }

    private func failApprovedAction(actionSpan: TelemetrySpanToken, turnSpan: TelemetrySpanToken, action: Action, resultCategory: String) async {
        _ = try? await self.telemetryRecorder.failSpan(actionSpan, fields: self.actionFields(action, state: "failed") + [self.stringField("resultCategory", resultCategory)])
        _ = try? await self.telemetryRecorder.failSpan(turnSpan, fields: self.baseFields(phase: "turn", state: "failed") + [self.stringField("resultCategory", resultCategory)])
    }

    private func requirePendingProposal(matching proposal: ActionProposal) throws -> PendingProposalState {
        guard let pending = self.pendingProposalState else { throw AssistantSessionError.noPendingProposal }
        guard pending.proposal == proposal else { throw AssistantSessionError.proposalMismatch(expected: pending.proposal, received: proposal) }
        return pending
    }

    private func baseFields(phase: String, state: String) -> [TelemetryField] {
        [self.stringField("phase", phase), self.stringField("state", state), self.stringField("source", "text")]
    }

    private func actionFields(_ action: Action, state: String) -> [TelemetryField] {
        self.baseFields(phase: "action", state: state) + self.actionIdentityFields(action)
    }

    private func actionIdentityFields(_ action: Action) -> [TelemetryField] {
        [self.stringField("actionName", action.name), self.stringField("actionDomain", action.domain.rawValue), self.stringField("actionKind", action.kind.rawValue)]
    }

    private func stringField(_ key: String, _ value: String) -> TelemetryField {
        TelemetryField(key: key, value: .string(value), visibility: .publicDebug)
    }

    private func intField(_ key: String, _ value: Int) -> TelemetryField {
        TelemetryField(key: key, value: .integer(value), visibility: .publicDebug)
    }
}
