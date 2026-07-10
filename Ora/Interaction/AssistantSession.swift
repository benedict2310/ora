import Foundation

enum AssistantSessionError: Error, Sendable, Equatable {
    case noPendingProposal
    case proposalMismatch(expected: ActionProposal, received: ActionProposal)
}

actor AssistantSession {
    private struct PendingProposalState: Sendable, Equatable {
        let turnID: TelemetryTurnID
        let turnSpan: TelemetrySpanToken
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

        do {
            let output = try await self.generator.generate(for: request)
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
                return .result(AssistantTurnResult(turnID: request.turnID, message: message))
            case .action(let name):
                guard let action = self.actionHost.catalog.action(named: name) else {
                    return await self.failTurn(
                        turnID: request.turnID,
                        turnSpan: turnSpan,
                        message: "Sorry, Ora v2 does not support that action.",
                        resultCategory: "unsupported_action"
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
        } catch StructuredOutputGenerationError.validationFailed {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: request.turnID, turnSpan: turnSpan)
            }
            return await self.failTurn(
                turnID: request.turnID,
                turnSpan: turnSpan,
                message: "Sorry, I couldn't understand that request.",
                resultCategory: "validation_failed"
            )
        } catch {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: request.turnID, turnSpan: turnSpan)
            }
            return await self.failTurn(
                turnID: request.turnID,
                turnSpan: turnSpan,
                message: "Sorry, I couldn't complete that request.",
                resultCategory: "generation_failed"
            )
        }
    }

    func approve(proposal: ActionProposal) async throws -> AssistantTurnOutcome {
        let pending = try self.requirePendingProposal(matching: proposal)
        self.pendingProposalState = nil

        _ = await self.telemetryRecorder.record(
            .actionProposalApproved,
            turnID: pending.turnID,
            fields: self.actionFields(proposal.action, state: "proposal_approved")
        )

        let actionSpan = await self.telemetryRecorder.beginSpan(
            .actionExecution,
            turnID: pending.turnID,
            fields: self.actionFields(proposal.action, state: "execution_started")
        )

        let result: ActionResult
        do {
            result = try await self.actionHost.execute(
                actionNamed: proposal.action.name,
                approval: .approved(proposal)
            )
        } catch {
            await self.failApprovedAction(
                actionSpan: actionSpan,
                turnSpan: pending.turnSpan,
                action: proposal.action,
                resultCategory: "action_failed"
            )
            throw error
        }

        switch result {
        case .executed(let action, let summary):
            _ = try? await self.telemetryRecorder.endSpan(
                actionSpan,
                fields: self.actionFields(action, state: "completed") + [
                    self.stringField("resultCategory", "executed")
                ]
            )

            let auditEntry = AuditEntry(
                turnID: pending.turnID,
                actionName: action.name,
                actionDomain: action.domain,
                actionKind: action.kind,
                summary: summary
            )
            await self.auditStore.record(auditEntry)
            _ = await self.telemetryRecorder.record(
                .auditEntryRecorded,
                turnID: pending.turnID,
                fields: self.baseFields(phase: "audit", state: "recorded") + self.actionIdentityFields(action) + [
                    self.intField("count", 1)
                ]
            )
            _ = try? await self.telemetryRecorder.endSpan(
                pending.turnSpan,
                fields: self.baseFields(phase: "turn", state: "completed") + [
                    self.stringField("resultCategory", "executed")
                ]
            )
            return .result(AssistantTurnResult(turnID: pending.turnID, message: summary))
        case .proposed:
            await self.failApprovedAction(
                actionSpan: actionSpan,
                turnSpan: pending.turnSpan,
                action: proposal.action,
                resultCategory: "unexpected_proposal"
            )
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
            let result = try await self.actionHost.execute(actionNamed: action.name, approval: nil)
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
            }

            switch result {
            case .proposed(let hostProposal):
                let proposal = hostProposal.withProposalID(self.proposalID(turnID: turnID, action: action))
                self.pendingProposalState = PendingProposalState(
                    turnID: turnID,
                    turnSpan: turnSpan,
                    proposal: proposal
                )
                _ = await self.telemetryRecorder.record(
                    .actionProposalCreated,
                    turnID: turnID,
                    fields: self.actionFields(action, state: "proposal_created")
                )
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
                    resultCategory: "mutation_executed_without_approval"
                )
            }
        } catch {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleTurn(turnID: turnID, turnSpan: turnSpan)
            }
            return await self.failTurn(
                turnID: turnID,
                turnSpan: turnSpan,
                message: "Sorry, I couldn't prepare that action for confirmation.",
                resultCategory: "proposal_failed"
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
            case .executed(_, let summary):
                _ = try? await self.telemetryRecorder.endSpan(
                    actionSpan,
                    fields: self.actionFields(action, state: "completed") + [
                        self.stringField("resultCategory", "executed")
                    ]
                )
                _ = try? await self.telemetryRecorder.endSpan(
                    turnSpan,
                    fields: self.baseFields(phase: "turn", state: "completed") + [
                        self.stringField("resultCategory", "executed")
                    ]
                )
                return .result(AssistantTurnResult(turnID: turnID, message: summary))
            case .proposed(let proposal):
                self.pendingProposalState = PendingProposalState(turnID: turnID, turnSpan: turnSpan, proposal: proposal)
                _ = try? await self.telemetryRecorder.cancelSpan(actionSpan)
                _ = await self.telemetryRecorder.record(
                    .actionProposalCreated,
                    turnID: turnID,
                    fields: self.actionFields(proposal.action, state: "proposal_created")
                )
                return .proposal(AssistantTurnProposal(turnID: turnID, proposal: proposal, message: proposal.summary))
            }
        } catch {
            guard self.isCurrentTextTurn(turnGeneration) else {
                return await self.cancelStaleActionTurn(
                    actionSpan: actionSpan,
                    turnSpan: turnSpan,
                    action: action,
                    turnID: turnID
                )
            }
            _ = try? await self.telemetryRecorder.failSpan(
                actionSpan,
                fields: self.actionFields(action, state: "failed") + [
                    self.stringField("resultCategory", "action_failed")
                ]
            )
            return await self.failTurn(
                turnID: turnID,
                turnSpan: turnSpan,
                message: "Sorry, I couldn't complete that request.",
                resultCategory: "action_failed",
                actionName: action.name
            )
        }
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
        return .cancelled(
            AssistantTurnCancellation(
                turnID: turnID,
                message: "Okay, I moved on to the latest request."
            )
        )
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
        actionName: String? = nil
    ) async -> AssistantTurnOutcome {
        var fields = self.baseFields(phase: "turn", state: "failed") + [
            self.stringField("resultCategory", resultCategory)
        ]
        if let actionName {
            fields.append(self.stringField("actionName", actionName))
        }
        _ = try? await self.telemetryRecorder.failSpan(turnSpan, fields: fields)
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

    private func proposalID(turnID: TelemetryTurnID, action: Action) -> String {
        "\(turnID.rawValue):\(action.name)"
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
