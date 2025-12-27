# Tools Epic

Implement agentic tools for Calendar, Reminders, Contacts, and System actions.

## Overview

This epic provides the tools that Ora can execute on behalf of the user:
- Calendar: query, find slots, create, delete events
- Reminders: list, create, complete, delete
- Contacts: search, lookup
- System: open apps, open URLs

## Prerequisites

- **Foundations:** F.02 (Permissions), F.08 (Persistence)

## Story Index

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **X.01** | [Tool Protocol](X.01-TOOL-PROTOCOL.md) | Base tool interface, registry, guardrails | F.02 |
| **X.02** | [Calendar Tools](X.02-CALENDAR-TOOLS.md) | EventKit integration for calendar | X.01, F.02 |
| **X.03** | [Reminders Tools](X.03-REMINDERS-TOOLS.md) | EventKit integration for reminders | X.01, F.02 |
| **X.04** | [Contacts Tools](X.04-CONTACTS-TOOLS.md) | Contacts framework integration | X.01, F.02 |
| **X.05** | [System Tools](X.05-SYSTEM-TOOLS.md) | App launching, URL opening | X.01 |

## Dependency Graph

```
F.02 (Permissions) ──► X.01 (Tool Protocol)
                            │
                            ├──► X.02 (Calendar)
                            │
                            ├──► X.03 (Reminders)
                            │
                            ├──► X.04 (Contacts)
                            │
                            └──► X.05 (System)
```

## Architecture Alignment

From `ARCHITECTURE.md`:
```
[ToolHost actor] ---> (EventKit / Contacts / Reminders / Safe Actions)
      |   \
      |    \---> [ConfirmationGate @MainActor] (mutations require explicit consent)
```

## Key Interfaces

```swift
protocol Tool: Sendable {
    var name: String { get }
    var kind: ToolKind { get }  // read or mutate
    var schema: JSONSchema { get }
    func validate(args: JSONValue) throws
    func execute(args: JSONValue) async throws -> ToolResult
}

struct ToolResult: Sendable {
    let json: JSONValue
    let humanSummary: String
}
```

## Guardrails

| Tool Type | Confirmation Required |
|:----------|:---------------------|
| Query/Search | No |
| Create | Yes |
| Delete | Yes |
| Open App/URL | No |

## Success Criteria

- [ ] All tools conform to `Tool` protocol
- [ ] Mutations require user confirmation
- [ ] All tool calls logged to audit log
- [ ] Clean error messages for permission failures
- [ ] Tools return both JSON and human summary
