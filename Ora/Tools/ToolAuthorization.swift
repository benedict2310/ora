//
//  ToolAuthorization.swift
//  Ora
//
//  Shared authorization models used by ToolHost, AgentLoop, and the overlay UI.
//

import Foundation

struct ToolExecutionTicket: Sendable, Equatable {
    let id: UUID
    let toolName: String
    let args: [String: JSONValue]
    let issuedAt: Date

    init(
        id: UUID = UUID(),
        toolName: String,
        args: [String: JSONValue],
        issuedAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.args = args
        self.issuedAt = issuedAt
    }
}

struct ToolAuthorizationReceipt: Sendable, Equatable {
    let id: UUID
    let ticketID: UUID
    let toolName: String
    let decision: ToolAuthorizationDecision
    let issuedAt: Date

    init(
        id: UUID = UUID(),
        ticketID: UUID,
        toolName: String,
        decision: ToolAuthorizationDecision,
        issuedAt: Date = Date()
    ) {
        self.id = id
        self.ticketID = ticketID
        self.toolName = toolName
        self.decision = decision
        self.issuedAt = issuedAt
    }
}

enum ToolPreflightDisposition: Sendable, Equatable {
    case allowed(receipt: ToolAuthorizationReceipt)
    case requiresUser(prompt: ToolAuthorizationPrompt)
}

struct ToolPreflightResult: Sendable, Equatable {
    let ticket: ToolExecutionTicket
    let disposition: ToolPreflightDisposition
}
