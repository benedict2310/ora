import Foundation

struct AuditEntry: Sendable, Equatable {
    let turnID: TelemetryTurnID
    let actionName: String
    let actionDomain: ActionDomain
    let actionKind: ActionKind
    let summary: String
}

protocol AuditStoring: Sendable {
    func record(_ entry: AuditEntry) async
    func entries() async -> [AuditEntry]
}

actor InMemoryAuditStore: AuditStoring {
    private var storedEntries: [AuditEntry] = []

    func record(_ entry: AuditEntry) async {
        self.storedEntries.append(entry)
    }

    func entries() async -> [AuditEntry] {
        self.storedEntries
    }
}
