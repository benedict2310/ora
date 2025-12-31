# Liquid Glass Chat UI (macOS Overlay)

## Overview

This guide defines a floating Liquid Glass chat UI for macOS, with:
- User bubbles on the left (blue tint).
- Agent bubbles on the right (neutral tint).
- Agent states for thinking and tool execution.
- A glass-first overlay look (no standard window chrome).

The glass layer should sit behind the chat content. Text and icons stay clear and readable above the glass.

---

## Layout Principles

**Alignment**
- User: left aligned.
- Agent: right aligned.
- Keep a consistent max width so the overlay feels deliberate (not full width).

**Visual hierarchy**
1. Glass bubble container (single layer per message).
2. Content (text, icons, state indicators) above the glass.

**Spacing**
- 8-12pt vertical spacing between messages.
- 12-16pt internal padding inside each bubble.

---

## Bubble Variants

**User Bubble (left, tinted blue)**
- `Glass.regular` with a blue tint.
- Capsule or rounded rectangle with continuous corners.

**Agent Bubble (right, neutral)**
- `Glass.regular` with a subtle neutral tint or none.
- Rounded rectangle for a calmer, grounded feel.

**Thinking State (agent)**
- Neutral tint + subtle shimmer or pulsing dots.
- Keep it quiet and low-motion to avoid fatigue.

**Tool State (agent)**
- Neutral tint + inline status row (icon + short text).
- Example: "Writing an event to your calendar".

---

## SwiftUI Example

```swift
struct GlassChatOverlay: View {
    let messages: [ChatMessage]

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { message in
                    bubble(for: message)
                }
            }
            .frame(maxWidth: 520, alignment: .center)
        }
        .padding(20)
    }

    @ViewBuilder
    private func bubble(for message: ChatMessage) -> some View {
        HStack {
            if message.role == .user {
                bubbleContent(message)
                    .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 24)
                bubbleContent(message)
                    .frame(maxWidth: 360, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func bubbleContent(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .leading : .trailing, spacing: 8) {
            if let state = message.state {
                stateRow(state)
            }

            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(glassStyle(for: message), in: bubbleShape(for: message))
    }

    private func glassStyle(for message: ChatMessage) -> Glass {
        switch message.role {
        case .user:
            return .regular.tint(.blue.opacity(0.6))
        case .agent:
            return .regular.tint(.white.opacity(0.08))
        }
    }

    private func bubbleShape(for message: ChatMessage) -> some Shape {
        if message.role == .user {
            return Capsule()
        }
        return RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    @ViewBuilder
    private func stateRow(_ state: ChatMessage.State) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.iconName)
                .font(.caption)
            Text(state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

```swift
struct ChatMessage: Identifiable {
    enum Role { case user, agent }
    struct State {
        let iconName: String
        let label: String
    }

    let id = UUID()
    let role: Role
    let text: String
    let state: State?
}
```

---

## States

**Thinking**
- `state.iconName`: `"ellipsis"` or `"brain"`
- `state.label`: `"Thinking"`
- Optional: add animated dots via a separate view.

**Tool Use**
- `state.iconName`: `"calendar"`, `"checkmark.circle"`, `"wand.and.stars"`
- `state.label`: short verb phrase, e.g. "Writing an event to your calendar"

---

## Motion

- Use a short drop-in animation for new messages: `.transition(.move(edge: .top).combined(with: .opacity))`.
- Keep `GlassEffectContainer` stable; only message rows animate in.
- Avoid continuous animation on the entire overlay.

---

## Accessibility

- Respect Reduced Transparency: fall back to `.identity` when needed.
- Keep contrast high for message text.
- Keep state labels short and legible.

---

## AppKit Overlay Setup (Reference)

```swift
let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
    styleMask: [.nonactivatingPanel, .borderless],
    backing: .buffered,
    defer: false
)
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]
panel.isOpaque = false
panel.backgroundColor = .clear
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false
```

---

## Sources

- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- https://developer.apple.com/documentation/appkit/nspanel
- https://developer.apple.com/documentation/appkit/nswindow/level
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior
