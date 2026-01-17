# UX Epic

Overlay-focused user experience improvements for clarity, interaction, and visual polish.

## Prerequisites

- **Foundations:** F.07 (Overlay Window), F.10 (Liquid Glass Overlay Refresh)

## Story Index

| Story | Title | Description | Dependencies | Status |
|-------|-------|-------------|--------------|--------|
| **UX.00** | [Overlay Bubble Spacing](UX.00-OVERLAY-BUBBLE-SPACING.md) | Standardize spacing to reduce glass outline seams | F.07 | Open |
| **UX.01** | [Agent Transparency Status](UX.01-AGENT-TRANSPARENCY-STATUS.md) | Show agent activity during planning and tool use | O.03, O.06, F.10 | Complete |
| **UX.02** | [Overlay Bubble Copy Action](UX.02-OVERLAY-BUBBLE-COPY.md) | Hover copy action for overlay bubbles | F.10 | Complete |
| **UX.03** | [Overlay Visual Polish](UX.03-OVERLAY-VISUAL-POLISH.md) | Spacing, styling, and motion refinements | F.10 | To Do |

---

## Core Architectural Patterns

### Agent Transparency Data Flow

Activity states flow from the agent loop to the UI through a unidirectional pipeline:

```
AgentLoop (actor)
    │
    ├── notifyDelegateActivity(.planning)
    ├── notifyDelegateActivity(.toolCall(name:))
    ├── notifyDelegateActivity(.toolResult(name:))
    └── notifyDelegateActivity(.composing)
            │
            ▼
SimplePipelineController (AgentLoopDelegate)
    │
    └── agentLoop(_:didUpdateActivity:)
            │
            ▼
        updateOverlayActivity(from:)
            │
            ▼
OverlayViewModel.activity (@Published)
            │
            ▼
OverlayView (observes via @EnvironmentObject)
            │
            ├── VoiceInputControlView (idle label)
            └── ChatBubbleView (state row)
```

### State Enums

**AgentActivity** (backend, in `AgentLoop.swift`):
- `.planning` - Reasoning before tool calls or response
- `.toolCall(name: String)` - About to call a tool
- `.toolResult(name: String)` - Processing tool result
- `.composing` - Generating response text
- `.waiting` - Awaiting user follow-up

**OverlayActivity** (UI, in `OverlayState.swift`):
- Maps 1:1 with AgentActivity
- Provides `displayLabel` for human-readable text
- Provides `toolLabel(for:)` to map tool names to friendly labels (e.g., `calendar.query` → "Calendar")

**ChatBubbleView.State** (visual, in `ChatBubbleView.swift`):
- `.thinking(String?)` - Shows spinner + optional label
- `.tool(String)` - Shows gear icon + tool description

### Two-Layer State Machine

The overlay uses two complementary state layers:

1. **OverlayMode** (primary): Coarse pipeline state
   - `.listening`, `.thinking`, `.responding`, `.executing`, `.awaitingFollowUp`, etc.
   - Drives major UI layout changes (which views are visible)

2. **OverlayActivity** (secondary): Fine-grained agent feedback
   - Updates rapidly during agent processing
   - Drives label text within existing views
   - Never triggers layout changes, only content updates

### Bubble State Pattern

Dynamic agent states are shown inside chat bubbles, not in separate status areas:

```swift
// Good: State shown in bubble context
ChatBubbleView(
    text: nil,
    role: .assistant,
    state: .thinking("Thinking"),  // Dynamic label
    ...
)

// Good: Tool operations get dedicated bubbles
if viewModel.activity.isToolOperation {
    ChatBubbleView(
        text: nil,
        role: .tool,
        state: .tool(viewModel.activity.displayLabel),
        ...
    )
}
```

### Deduplication

Activity updates are deduplicated at the source to prevent UI flicker:

```swift
// AgentLoop.swift
private func notifyDelegateActivity(_ activity: AgentActivity) async {
    if currentActivity == activity { return }  // Dedup
    currentActivity = activity
    await MainActor.run { ... }
}
```

### Tool Activity Reveal

Tool call/result bubbles only appear if the tool activity persists beyond a short delay (200ms).
This avoids "flash" bubbles for fast operations without delaying normal activity updates.

### Tool Label Mapping

Technical tool names are mapped to user-friendly labels:

| Tool Prefix | Display Label |
|-------------|---------------|
| `calendar.*` | Calendar |
| `reminders.*` | Reminders |
| `contacts.*` | Contacts |
| `system.run_shortcut`, `system.list_shortcuts` | Shortcuts |
| `system.*` | System |
| (other) | Tool |
