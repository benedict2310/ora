//
//  ChatBubbleView.swift
//  Ora
//
//  Liquid-glass chat bubbles for the overlay
//

import AppKit
import SwiftUI

// MARK: - Pasteboard Abstraction

/// Protocol for pasteboard writing, enabling test injection
protocol PasteboardWriting: Sendable {
    @MainActor func setString(_ string: String)
}

/// Default implementation using the system pasteboard
struct SystemPasteboard: PasteboardWriting {
    @MainActor func setString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Chat Bubble View

struct ChatBubbleView: View {
    enum Role {
        case user
        case assistant
        case tool
    }

    enum BubbleState: Equatable {
        /// Thinking/planning state with optional dynamic label
        case thinking(String?)
        /// Tool operation state with description
        case tool(String)
    }

    let text: String?
    let role: Role
    let state: BubbleState?
    let isPartial: Bool
    let reduceTransparency: Bool
    let reduceMotion: Bool
    var pasteboard: PasteboardWriting = SystemPasteboard()

    @State private var isHovered: Bool = false
    @State private var isCopied: Bool = false

    private let maxBubbleWidth: CGFloat = 360
    private let bubbleInset: CGFloat = 24

    var body: some View {
        let alignment = self.role == .user ? BubbleAlignment.leading : BubbleAlignment.trailing
        return self.bubbleRow(alignment: alignment) {
            self.bubbleContent
                .overlay(alignment: .topTrailing) {
                    if self.shouldShowCopyButton {
                        self.copyButton
                    }
                }
        }
        .onHover { hovering in
            self.isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityHint(self.accessibilityHint)
        .accessibilityAction(named: "Copy") {
            self.copyToClipboard()
        }
    }

    /// Whether to show the copy button (only for non-empty text, not state-only bubbles)
    private var shouldShowCopyButton: Bool {
        guard let text = self.text, !text.isEmpty else { return false }
        // Don't show copy button on state-only bubbles (thinking/tool states without text)
        if self.state != nil && self.text == nil { return false }
        return self.isHovered
    }

    @ViewBuilder
    private var copyButton: some View {
        Button {
            self.copyToClipboard()
        } label: {
            Image(systemName: self.isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(self.isCopied ? .green : .secondary)
                .frame(width: 24, height: 24)
                .background {
                    if self.reduceTransparency {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(6)
        .transition(self.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.isHovered)
        .accessibilityLabel(self.isCopied ? "Copied" : "Copy to clipboard")
        .accessibilityAddTraits(.isButton)
    }

    private func copyToClipboard() {
        guard let text = self.text, !text.isEmpty else { return }
        self.pasteboard.setString(text)
        self.isCopied = true

        // Reset copied state after delay
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.isCopied = false
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        let shape = self.bubbleShape(for: self.role)
        let base = VStack(alignment: self.role == .user ? .leading : .trailing, spacing: OverlayLayout.bubbleContentSpacing) {
            if let state = self.state {
                self.stateRow(state, alignRight: self.role != .user)
            }

            if let text = self.text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, OverlayLayout.bubblePaddingHorizontal)
        .padding(.vertical, OverlayLayout.bubblePaddingVertical)
        .opacity(self.isPartial ? 0.8 : 1.0)

        if self.reduceTransparency {
            base
                .userChromaOverlay(
                    enabled: self.role == .user,
                    shape: shape
                )
                .background(shape.fill(self.baseFillColor(for: self.role)))
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6))
        } else {
            // Fix B: glassEffect must be LAST to avoid black outline artifacts
            base
                .userChromaOverlay(
                    enabled: self.role == .user,
                    shape: shape
                )
                .glassEffect(self.glassStyle(for: self.role), in: shape)
        }
    }

    private func bubbleRow(
        alignment: BubbleAlignment,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack {
            if alignment == .leading {
                content()
                    .frame(maxWidth: self.maxBubbleWidth, alignment: .leading)
                Spacer(minLength: self.bubbleInset)
            } else {
                Spacer(minLength: self.bubbleInset)
                content()
                    .frame(maxWidth: self.maxBubbleWidth, alignment: .trailing)
            }
        }
    }

    private func glassStyle(for role: Role) -> Glass {
        // Use .regular variant for full background adaptivity (light/dark)
        // Tint opacities lowered to reduce black outline artifacts at glass boundaries
        switch role {
        case .user:
            return .regular.tint(Color(red: 0.12, green: 0.55, blue: 0.95).opacity(0.25))
        case .assistant:
            return .regular.tint(.white.opacity(0.03))
        case .tool:
            return .regular.tint(.white.opacity(0.04))
        }
    }

    private func baseFillColor(for role: Role) -> Color {
        switch role {
        case .user:
            return Color(red: 0.12, green: 0.55, blue: 0.95).opacity(0.35)
        case .assistant:
            return Color(nsColor: .windowBackgroundColor).opacity(0.92)
        case .tool:
            return Color(nsColor: .controlBackgroundColor).opacity(0.92)
        }
    }

    private func bubbleShape(for role: Role) -> AnyShape {
        if role == .user {
            return AnyShape(Capsule())
        }
        return AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stateRow(_ state: BubbleState, alignRight: Bool) -> some View {
        let textFont: Font
        switch state {
        case .thinking:
            textFont = .body.weight(.semibold)
        case .tool:
            textFont = .caption
        }

        return HStack(spacing: 6) {
            switch state {
            case .thinking(let label):
                if self.reduceMotion {
                    Image(systemName: "ellipsis")
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(label ?? "Thinking")
            case .tool(let label):
                Image(systemName: "gearshape")
                    .font(.caption)
                Text(label)
            }
        }
        .font(textFont)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }

    private var accessibilityLabel: String {
        Self.accessibilityLabel(for: self.role, text: self.text)
    }

    private var accessibilityHint: String {
        Self.accessibilityHint(isPartial: self.isPartial)
    }

    static func accessibilityLabel(for role: Role, text: String?) -> String {
        let roleLabel = Self.roleLabel(for: role)
        if let text = text, !text.isEmpty {
            return "\(roleLabel): \(text)"
        }
        return roleLabel
    }

    static func accessibilityHint(isPartial: Bool) -> String {
        isPartial ? "Partial transcription" : ""
    }

    static func roleLabel(for role: Role) -> String {
        switch role {
        case .user:
            return "You said"
        case .assistant:
            return "Ora said"
        case .tool:
            return "Ora tool"
        }
    }

    // MARK: - Test Helpers

    /// Whether the bubble has text content that can be copied
    var hasCopyableContent: Bool {
        guard let text = self.text, !text.isEmpty else { return false }
        return true
    }

    /// Perform the copy action (for testing)
    func performCopy() {
        self.copyToClipboard()
    }

    /// Get the accessibility label for the copy button (for testing)
    func copyButtonAccessibilityLabel(copied: Bool) -> String {
        copied ? "Copied" : "Copy to clipboard"
    }
}

private enum BubbleAlignment {
    case leading
    case trailing
}

struct AnyShape: Shape, @unchecked Sendable {
    private let pathBuilder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        self.pathBuilder = { rect in
            shape.path(in: rect)
        }
    }

    func path(in rect: CGRect) -> Path {
        self.pathBuilder(rect)
    }
}

private extension View {
    @ViewBuilder
    func userChromaOverlay(enabled: Bool, shape: AnyShape) -> some View {
        if enabled {
            self
                .overlay(
                    shape.fill(Color(red: 0.32, green: 0.65, blue: 0.98).opacity(0.22))
                )
                .overlay(
                    shape.stroke(Color(red: 0.48, green: 0.78, blue: 1.0).opacity(0.35), lineWidth: 0.6)
                )
        } else {
            self
        }
    }
}
