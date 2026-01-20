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
    /// Optional namespace for glassEffectUnion to group bubbles into a single glass region.
    /// When provided, all bubbles sharing the same namespace and ID will render as one unified glass.
    var glassUnionNamespace: Namespace.ID?
    var pasteboard: PasteboardWriting = SystemPasteboard()

    @State private var isHovered: Bool = false
    @State private var isCopied: Bool = false
    @State private var hoverHideTask: Task<Void, Never>?

    /// Maximum bubble width based on role
    private var maxBubbleWidth: CGFloat {
        self.role == .user ? OverlayLayout.userBubbleMaxWidth : OverlayLayout.assistantBubbleMaxWidth
    }

    var body: some View {
        let alignment = self.role == .user ? BubbleAlignment.leading : BubbleAlignment.trailing
        return self.bubbleRow(alignment: alignment) {
            self.bubbleContent
                // Position copy button outside bubble bounds
                .overlay(alignment: self.role == .user ? .topTrailing : .topLeading) {
                    if self.shouldShowCopyButton {
                        self.copyButton
                            .offset(x: self.role == .user ? 32 : -32, y: 6)
                    }
                }
        }
        .onHover { hovering in
            // Cancel any pending hide task
            self.hoverHideTask?.cancel()
            self.hoverHideTask = nil

            if hovering {
                // Show immediately on enter
                if self.reduceMotion {
                    self.isHovered = true
                } else {
                    withAnimation(.bouncy(duration: 0.3)) {
                        self.isHovered = true
                    }
                }
            } else {
                // Delay hiding to prevent flickering at edges
                self.hoverHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    if self.reduceMotion {
                        self.isHovered = false
                    } else {
                        withAnimation(.bouncy(duration: 0.3)) {
                            self.isHovered = false
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityHint(self.accessibilityHint)
        .accessibilityAction(named: "Copy") {
            self.copyToClipboard()
        }
    }

    /// Whether to show the copy button (only for non-empty text bubbles on hover)
    private var shouldShowCopyButton: Bool {
        guard let text = self.text, !text.isEmpty else { return false }
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
        }
        .buttonStyle(.glass)
        .controlSize(.small)
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

        // Original structure: glass effect applied directly to base, no extra wrappers
        if self.reduceTransparency {
            base
                .userChromaOverlay(
                    enabled: self.role == .user,
                    shape: shape
                )
                .background(shape.fill(self.baseFillColor(for: self.role)))
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6))
        } else {
            // When using glassEffectUnion, all bubbles must have identical glass style.
            // Role differentiation is achieved via background overlays instead of glass tints.
            let useUnifiedGlass = self.glassUnionNamespace != nil

            base
                // Role differentiation via background overlays (works with glassEffectUnion)
                .background(
                    shape.fill(self.roleBackgroundColor(for: self.role))
                )
                // User bubbles get blue chroma overlay for additional accent
                .userChromaOverlay(
                    enabled: self.role == .user,
                    shape: shape
                )
                // Neutral background for glass to sample (text color adaptation)
                .neutralGlassBackground(
                    enabled: self.role != .user && !useUnifiedGlass,
                    shape: shape
                )
                .glassEffect(self.glassStyle(for: self.role, unified: useUnifiedGlass), in: shape)
                // Apply glassEffectUnion when namespace is provided to eliminate boundary artifacts
                .glassEffectUnion(
                    id: "chatBubbles",
                    namespace: self.glassUnionNamespace,
                    enabled: useUnifiedGlass
                )
                // Force compositing to ensure glass samples background correctly on initial render
                .compositingGroup()
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
                Spacer(minLength: OverlayLayout.bubbleInset)
            } else {
                Spacer(minLength: OverlayLayout.bubbleInset)
                content()
                    .frame(maxWidth: self.maxBubbleWidth, alignment: .trailing)
            }
        }
    }

    private func glassStyle(for role: Role, unified: Bool = false) -> Glass {
        // When using glassEffectUnion, all bubbles must have IDENTICAL glass style.
        // Role differentiation is achieved via background overlays instead of glass tints.
        if unified {
            // Unified neutral tint for glassEffectUnion - eliminates boundary artifacts
            return .regular.tint(.white.opacity(0.03))
        }

        // Use .regular variant for full background adaptivity (light/dark)
        // Text adaptation works because user bubbles have chroma overlay and
        // assistant/tool bubbles have neutral background for glass to sample
        switch role {
        case .user:
            return .regular.tint(Color(red: 0.12, green: 0.55, blue: 0.95).opacity(0.25))
        case .assistant:
            return .regular.tint(.white.opacity(0.03))
        case .tool:
            return .regular.tint(.white.opacity(0.04))
        }
    }

    /// Background color for role differentiation when using glassEffectUnion.
    /// This replaces glass tint differentiation to maintain visual distinction between roles.
    private func roleBackgroundColor(for role: Role) -> Color {
        switch role {
        case .user:
            // Blue accent for user messages
            return Color(red: 0.12, green: 0.55, blue: 0.95).opacity(0.12)
        case .assistant:
            // Very subtle for assistant
            return Color.white.opacity(0.02)
        case .tool:
            // Slightly more visible for tool messages
            return Color.white.opacity(0.03)
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

    /// Adds a subtle neutral background for glass to sample, enabling text color adaptation
    @ViewBuilder
    func neutralGlassBackground(enabled: Bool, shape: AnyShape) -> some View {
        if enabled {
            self
                .background(
                    shape.fill(Color.gray.opacity(0.15))
                )
        } else {
            self
        }
    }

    /// Conditionally applies glassEffectUnion to group multiple glass elements into one region.
    /// This eliminates boundary artifacts between adjacent glass elements.
    @ViewBuilder
    func glassEffectUnion(id: String, namespace: Namespace.ID?, enabled: Bool) -> some View {
        if enabled, let namespace = namespace {
            self.glassEffectUnion(id: id, namespace: namespace)
        } else {
            self
        }
    }
}
