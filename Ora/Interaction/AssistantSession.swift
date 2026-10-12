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
            .turn,
            turnID: request.turnID,
            fields: self.baseFields(phase: "turn", state: "started")
        )

        _ = await self.telemetryRecorder.record(
            .inputTextReceived,
            turnID: request.turnID,
            fields: self.baseFields(phase: "input", state: "received") + [
                self.intField("characterCount", request.text.count)
            ]
        )

        guard self.isCurrentTextTurn(turnGeneration) else {
            return await self.cancelStaleTurn(turnID: request.turnID, turnSpan: turnSpan)
        }
        do {
            try Task.checkCancellation()
            let output = try await self.generator.generate(for: request)
            try Task.checkCancellation()
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: request.turnID, turnSpan: turnSpan)
            }
            switch output {
            case .response(let message):
                _ = try? await self.telemetryRecorder.endSpan(
                    turnSpan,
                    fields: self.baseFields(phase: "turn", state: "completed") + [
                        self.stringField("resultCategory", "response")
                    ]
                )
                guard self.isCurrentTextTurn(turnGeneration) else {
                    return self.staleTurnCancellation(turnID: request.turnID)
                }
                return .result(AssistantTurnResult(turnID: request.turnID, message: message))
            case .action(let name):
                guard let action = self.actionHost.catalog.action(named: name) else {
                    return await self.failTurn(
                        turnID: request.turnID,
                        turnSpan: turnSpan,
                        message: "Sorry, Ora v2 does not support that action.",
                        resultCategory: "unsupported_action",
                        turnGeneration: turnGeneration
                    )
                }

                if action.requiresConfirmation {
                    return await self.prepareMutationProposal(
                        action: action,
                        turnID: request.turnID,
                        turnSpan: turnSpan,
                        turnGeneration: turnGeneration
                    )
                }

                return await self.executeReadAction(
                    action: action,
                    turnID: request.turnID,
                    turnSpan: turnSpan,
                    turnGeneration: turnGeneration
                )
            }
        } catch is CancellationError {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: request.turnID, turnSpan: turnSpan)
            }
            return await self.cancelUnapprovedTurn(
                turnID: request.turnID, turnSpan: turnSpan, turnGeneration: turnGeneration
            )
        } catch StructuredOutputGenerationError.validationFailed {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: request.turnID, turnSpan: turnSpan)
            }
            return await self.failTurn(
                turnID: request.turnID,
                turnSpan: turnSpan,
                message: "Sorry, I couldn't understand that request.",
                resultCategory: "validation_failed",
                turnGeneration: turnGeneration
            )
        } catch {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: request.turnID, turnSpan: turnSpan)
            }
            return await self.failTurn(
                turnID: request.turnID,
                turnSpan: turnSpan,
                message: "Sorry, I couldn't complete that request.",
                resultCategory: "generation_failed",
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
        case .proposed:
            await self.failApprovedAction(
                actionSpan: actionSpan,
                turnSpan: pending.turnSpan,
                action: approvedAction,
                resultCategory: "unexpected_proposal"
            )
            guard self.isCurrentTextTurn(pending.turnGeneration) else {
                return self.staleTurnCancellation(turnID: pending.turnID)
            }
            throw AssistantSessionError.proposalMismatch(expected: pending.proposal, received: proposal)
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

    private func prepareMutationProposal(
        action: Action,
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        turnGeneration: Int
    ) async -> AssistantTurnOutcome {
        do {
            try Task.checkCancellation()
            let result = try await self.actionHost.execute(actionNamed: action.name, approval: nil)
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
            }

            switch result {
            case .proposed(let hostProposal):
                try Task.checkCancellation()
                guard hostProposal.action == action else {
                    return await self.failTurn(
                        turnID: turnID, turnSpan: turnSpan,
                        message: "Sorry, I couldn't verify that action.",
                        resultCategory: "proposal_action_mismatch",
                        turnGeneration: turnGeneration, action: action
                    )
                }
                let proposal = hostProposal.withProposalID(UUID().uuidString)
                self.pendingProposalState = PendingProposalState(
                    turnID: turnID,
                    turnSpan: turnSpan,
                    turnGeneration: turnGeneration,
                    proposal: proposal
                )
                _ = await self.telemetryRecorder.record(
                    .actionProposalCreated,
                    turnID: turnID,
                    fields: self.actionFields(action, state: "proposal_created")
                )
                guard self.isPendingProposalStillCurrent(
                    PendingProposalState(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, proposal: proposal),
                    turnGeneration: turnGeneration
                ) else {
                    return self.staleTurnCancellation(turnID: turnID)
                }
                if Task.isCancelled {
                    self.pendingProposalState = nil
                    return await self.cancelUnapprovedTurn(
                        turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action
                    )
                }
                return .proposal(
                    AssistantTurnProposal(
                        turnID: turnID,
                        proposal: proposal,
                        message: proposal.summary
                    )
                )
            case .executed:
                return await self.failTurn(
                    turnID: turnID,
                    turnSpan: turnSpan,
                    message: "Sorry, that action needs confirmation before I can run it.",
                    resultCategory: "mutation_executed_without_approval",
                    turnGeneration: turnGeneration,
                    action: action
                )
            }
        } catch is CancellationError {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
            }
            return await self.cancelUnapprovedTurn(
                turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action
            )
        } catch {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
            }
            return await self.failTurn(
                turnID: turnID,
                turnSpan: turnSpan,
                message: "Sorry, I couldn't prepare that action for confirmation.",
                resultCategory: "proposal_failed",
                turnGeneration: turnGeneration,
                action: action
            )
        }
    }

    private func executeReadAction(
        action: Action,
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        turnGeneration: Int
    ) async -> AssistantTurnOutcome {
        let actionSpan = await self.telemetryRecorder.beginSpan(
            .actionExecution,
            turnID: turnID,
            fields: self.actionFields(action, state: "execution_started")
        )

        guard self.isCurrentTextTurn(turnGeneration) else {
            return await self.cancelStaleActionTurn(
                actionSpan: actionSpan,
                turnSpan: turnSpan,
                action: action,
                turnID: turnID
            )
        }

        do {
            try Task.checkCancellation()
            let result = try await self.actionHost.execute(actionNamed: action.name, approval: nil)
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleActionTurn(
                    actionSpan: actionSpan,
                    turnSpan: turnSpan,
                    action: action,
                    turnID: turnID
                )
            }
            switch result {
            case .executed(let returnedAction, let summary):
                guard returnedAction == action else {
                    return await self.failReadAction(
                        actionSpan: actionSpan, turnSpan: turnSpan, turnID: turnID,
                        action: action, resultCategory: "action_mismatch", turnGeneration: turnGeneration
                    )
                }
                _ = try? await self.telemetryRecorder.endSpan(
                    actionSpan,
                    fields: self.actionFields(action, state: "completed") + [
                        self.stringField("resultCategory", "executed")
                    ]
                )
                guard self.isCurrentTextTurn(turnGeneration) else {
                    return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
                }
                _ = try? await self.telemetryRecorder.endSpan(
                    turnSpan,
                    fields: self.baseFields(phase: "turn", state: "completed") + [
                        self.stringField("resultCategory", "executed")
                    ]
                )
                guard self.isCurrentTextTurn(turnGeneration) else {
                    return self.staleTurnCancellation(turnID: turnID)
                }
                return .result(AssistantTurnResult(turnID: turnID, message: summary))
            case .proposed(let hostProposal):
                try Task.checkCancellation()
                guard hostProposal.action == action else {
                    return await self.failReadAction(
                        actionSpan: actionSpan, turnSpan: turnSpan, turnID: turnID,
                        action: action, resultCategory: "proposal_action_mismatch", turnGeneration: turnGeneration
                    )
                }
                let proposal = hostProposal.withProposalID(UUID().uuidString)
                self.pendingProposalState = PendingProposalState(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, proposal: proposal)
                _ = try? await self.telemetryRecorder.cancelSpan(actionSpan)
                guard self.isPendingProposalStillCurrent(
                    PendingProposalState(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, proposal: proposal),
                    turnGeneration: turnGeneration
                ) else {
                    return self.staleTurnCancellation(turnID: turnID)
                }
                if Task.isCancelled {
                    self.pendingProposalState = nil
                    return await self.cancelUnapprovedTurn(
                        turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action
                    )
                }
                _ = await self.telemetryRecorder.record(
                    .actionProposalCreated,
                    turnID: turnID,
                    fields: self.actionFields(action, state: "proposal_created")
                )
                guard self.isPendingProposalStillCurrent(
                    PendingProposalState(turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, proposal: proposal),
                    turnGeneration: turnGeneration
                ) else {
                    return self.staleTurnCancellation(turnID: turnID)
                }
                if Task.isCancelled {
                    self.pendingProposalState = nil
                    return await self.cancelUnapprovedTurn(
                        turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action
                    )
                }
                return .proposal(AssistantTurnProposal(turnID: turnID, proposal: proposal, message: proposal.summary))
            }
        } catch is CancellationError {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleActionTurn(
                    actionSpan: actionSpan, turnSpan: turnSpan, action: action, turnID: turnID
                )
            }
            return await self.cancelUnapprovedActionTurn(
                actionSpan: actionSpan, turnSpan: turnSpan, turnID: turnID,
                turnGeneration: turnGeneration, action: action
            )
        } catch {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleActionTurn(
                    actionSpan: actionSpan,
                    turnSpan: turnSpan,
                    action: action,
                    turnID: turnID
                )
            }
            return await self.failReadAction(
                actionSpan: actionSpan, turnSpan: turnSpan, turnID: turnID,
                action: action, resultCategory: "action_failed", turnGeneration: turnGeneration
            )
        }
    }

    private func cancelUnapprovedActionTurn(
        actionSpan: TelemetrySpanToken,
        turnSpan: TelemetrySpanToken,
        turnID: TelemetryTurnID,
        turnGeneration: Int,
        action: Action
    ) async -> AssistantTurnOutcome {
        _ = try? await self.telemetryRecorder.cancelSpan(
            actionSpan,
            fields: self.actionFields(action, state: "cancelled") + [self.stringField("resultCategory", "task_cancelled")]
        )
        return await self.cancelUnapprovedTurn(
            turnID: turnID, turnSpan: turnSpan, turnGeneration: turnGeneration, action: action
        )
    }

    private func cancelUnapprovedTurn(
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        turnGeneration: Int,
        action: Action? = nil
    ) async -> AssistantTurnOutcome {
        var fields = self.baseFields(phase: "turn", state: "cancelled") + [
            self.stringField("resultCategory", self.isCurrentTextTurn(turnGeneration) ? "task_cancelled" : "replaced")
        ]
        if let action { fields += self.actionIdentityFields(action) }
        _ = try? await self.telemetryRecorder.cancelSpan(turnSpan, fields: fields)
        guard self.isCurrentTextTurn(turnGeneration) else {
            return self.staleTurnCancellation(turnID: turnID)
        }
        return .cancelled(AssistantTurnCancellation(turnID: turnID, message: "Okay, I cancelled that request."))
    }

    private func failReadAction(
        actionSpan: TelemetrySpanToken,
        turnSpan: TelemetrySpanToken,
        turnID: TelemetryTurnID,
        action: Action,
        resultCategory: String,
        turnGeneration: Int
    ) async -> AssistantTurnOutcome {
        _ = try? await self.telemetryRecorder.failSpan(
            actionSpan,
            fields: self.actionFields(action, state: "failed") + [self.stringField("resultCategory", resultCategory)]
        )
        return await self.failTurn(
            turnID: turnID, turnSpan: turnSpan,
            message: "Sorry, I couldn't complete that request.", resultCategory: resultCategory,
            turnGeneration: turnGeneration, action: action
        )
    }

    private func recordAuditTelemetry(action: Action, turnID: TelemetryTurnID) async {
        _ = await self.telemetryRecorder.record(
            .auditEntryRecorded,
            turnID: turnID,
            fields: self.baseFields(phase: "audit", state: "recorded") + self.actionIdentityFields(action) + [
                self.intField("count", 1)
            ]
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
        guard let pending = self.pendingProposalState else {
            return
        }
        self.pendingProposalState = nil
        _ = try? await self.telemetryRecorder.cancelSpan(
            pending.turnSpan,
            fields: self.baseFields(phase: "turn", state: "cancelled") + [
                self.stringField("resultCategory", "replaced")
            ]
        )
    }

    private func isPendingProposalStillCurrent(
        _ pending: PendingProposalState,
        turnGeneration: Int
    ) -> Bool {
        self.isCurrentTextTurn(turnGeneration) && self.pendingProposalState == pending
    }

    private func staleTurnCancellation(turnID: TelemetryTurnID) -> AssistantTurnOutcome {
        .cancelled(
            AssistantTurnCancellation(
                turnID: turnID,
                message: "Okay, I moved on to the latest request."
            )
        )
    }

    private func cancelStaleActionTurn(
        actionSpan: TelemetrySpanToken,
        turnSpan: TelemetrySpanToken,
        action: Action,
        turnID: TelemetryTurnID
    ) async -> AssistantTurnOutcome {
        _ = try? await self.telemetryRecorder.cancelSpan(
            actionSpan,
            fields: self.actionFields(action, state: "cancelled") + [
                self.stringField("resultCategory", "replaced")
            ]
        )
        return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
    }

    private func cancelStaleTurn(
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken
    ) async -> AssistantTurnOutcome {
        _ = try? await self.telemetryRecorder.cancelSpan(
            turnSpan,
            fields: self.baseFields(phase: "turn", state: "cancelled") + [
                self.stringField("resultCategory", "replaced")
            ]
        )
        return self.staleTurnCancellation(turnID: turnID)
    }

    private func failApprovedAction(
        actionSpan: TelemetrySpanToken,
        turnSpan: TelemetrySpanToken,
        action: Action,
        resultCategory: String
    ) async {
        _ = try? await self.telemetryRecorder.failSpan(
            actionSpan,
            fields: self.actionFields(action, state: "failed") + [
                self.stringField("resultCategory", resultCategory)
            ]
        )
        _ = try? await self.telemetryRecorder.failSpan(
            turnSpan,
            fields: self.baseFields(phase: "turn", state: "failed") + [
                self.stringField("resultCategory", resultCategory)
            ]
        )
    }

    private func failTurn(
        turnID: TelemetryTurnID,
        turnSpan: TelemetrySpanToken,
        message: String,
        resultCategory: String,
        turnGeneration: Int,
        action: Action? = nil
    ) async -> AssistantTurnOutcome {
        guard self.isCurrentTextTurn(turnGeneration) else {
            return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
        }
        var fields = self.baseFields(phase: "turn", state: "failed") + [
            self.stringField("resultCategory", resultCategory)
        ]
        if let action {
            fields += self.actionIdentityFields(action)
        }
        _ = try? await self.telemetryRecorder.failSpan(turnSpan, fields: fields)
        guard self.isCurrentTextTurn(turnGeneration) else {
            return self.staleTurnCancellation(turnID: turnID)
        }
        return .failure(AssistantTurnFailure(turnID: turnID, message: message))
    }

    private func requirePendingProposal(matching proposal: ActionProposal) throws -> PendingProposalState {
        guard let pending = self.pendingProposalState else {
            throw AssistantSessionError.noPendingProposal
        }
        guard pending.proposal == proposal else {
            throw AssistantSessionError.proposalMismatch(expected: pending.proposal, received: proposal)
        }
        return pending
    }

    private func baseFields(phase: String, state: String) -> [TelemetryField] {
        [
            self.stringField("phase", phase),
            self.stringField("state", state),
            self.stringField("source", "text")
        ]
    }

    private func actionFields(_ action: Action, state: String) -> [TelemetryField] {
        self.baseFields(phase: "action", state: state) + self.actionIdentityFields(action)
    }

    private func actionIdentityFields(_ action: Action) -> [TelemetryField] {
        [
            self.stringField("actionName", action.name),
            self.stringField("actionDomain", action.domain.rawValue),
            self.stringField("actionKind", action.kind.rawValue)
        ]
    }

    private func stringField(_ key: String, _ value: String) -> TelemetryField {
        TelemetryField(key: key, value: .string(value), visibility: .publicDebug)
    }

    private func intField(_ key: String, _ value: Int) -> TelemetryField {
        TelemetryField(key: key, value: .integer(value), visibility: .publicDebug)
    }
}
