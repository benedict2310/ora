import Foundation

enum ActionDomain: String, CaseIterable, Sendable {
    case calendar
    case reminders
    case contacts
    case system
    case memory
    case skills
    case research
    case backgroundTasks
    case mail
    case messages
    case notes
    case cloud
    case vision
    case automation

    static let v2Domains: Set<ActionDomain> = [
        .calendar,
        .reminders,
        .contacts,
        .system
    ]

    static let deprecatedDomains: Set<ActionDomain> = Set(Self.allCases).subtracting(Self.v2Domains)
}

enum ActionKind: String, Sendable {
    case read
    case mutation

    var requiresConfirmation: Bool {
        self == .mutation
    }
}

struct Action: Sendable, Equatable {
    let name: String
    let domain: ActionDomain
    let kind: ActionKind

    var requiresConfirmation: Bool {
        self.kind.requiresConfirmation
    }
}

extension Action {
    static let v2DefaultActions: [Action] = [
        Action(name: "calendar.query", domain: .calendar, kind: .read),
        Action(name: "calendar.find_slots", domain: .calendar, kind: .read),
        Action(name: "calendar.create", domain: .calendar, kind: .mutation),
        Action(name: "calendar.update", domain: .calendar, kind: .mutation),
        Action(name: "calendar.delete", domain: .calendar, kind: .mutation),
        Action(name: "reminders.list", domain: .reminders, kind: .read),
        Action(name: "reminders.create", domain: .reminders, kind: .mutation),
        Action(name: "reminders.update", domain: .reminders, kind: .mutation),
        Action(name: "reminders.complete", domain: .reminders, kind: .mutation),
        Action(name: "reminders.delete", domain: .reminders, kind: .mutation),
        Action(name: "contacts.search", domain: .contacts, kind: .read),
        Action(name: "system.open_app", domain: .system, kind: .read),
        Action(name: "system.open_url", domain: .system, kind: .read),
        Action(name: "system.open_settings", domain: .system, kind: .read)
    ]
}
