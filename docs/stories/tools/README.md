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
| **X.06** | [List Apps Tool](X.06-LIST-APPS-TOOL.md) | List installed applications | X.05 |
| **X.06C** | [Messages: Send & Open](X.06C-MESSAGES.md) | Send iMessage/SMS and open chats | X.00 |
| **X.07B** | [Mail: Search & Open](X.07B-MAIL-SEARCH.md) | Search mail, open messages, list mailboxes | X.07A |
| **X.08** | [Recent Items: Mail & Notes](X.08-RECENT-ITEMS.md) | Browse recent mail messages and notes | X.07B, X.06A |
| **X.09** | [Mail Multi-Account](X.09-MAIL-MULTI-ACCOUNT.md) | Query all accounts when none specified | X.07B, X.08 |

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
                                      │
                                      └──► X.06 (List Apps)
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

---

## Implementation Learnings

### Tool Result Context for Multi-Step Flows (Critical)

When the AgentLoop passes tool results back to the LLM, it must include the **full JSON data** (in compact format), not just the `humanSummary`. This is essential for multi-step agentic flows where the LLM needs to reference data from previous tool calls.

**Example:** To delete a calendar event, the LLM must first query events to get the `event_id`. If only the summary ("Found 3 events.") is passed back, the LLM cannot see the actual event IDs.

**Pattern in AgentLoop:**
```swift
// Include full JSON so LLM can reference IDs in subsequent operations
let jsonString = result.json.compactJSON
let resultText = "Tool \(tool) returned: \(jsonString)"
await conversationManager.addToolResult(resultText)
```

**When implementing new tools, ensure:**
1. Include identifiers (IDs, references) in the `json` field of `ToolResult`
2. Keep JSON compact to avoid token bloat
3. Add system prompt instructions if the LLM needs to query before mutating
