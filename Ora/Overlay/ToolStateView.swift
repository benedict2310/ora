//
//  ToolStateView.swift
//  Ora
//
//  Tool execution and proposal state blocks
//

import SwiftUI

struct ToolStateView: View {
    enum Mode: Equatable {
        case proposal(ToolProposal)
        case executing(label: String)
    }

    enum ToolStyle: Equatable {
        case delete
        case create
        case edit
        case complete
        case unknown
    }

    let mode: Mode
    let reduceTransparency: Bool
    let reduceMotion: Bool

    @FocusState private var confirmButtonFocused: Bool
    @FocusState private var cancelButtonFocused: Bool

    private let maxBubbleWidth: CGFloat = 360
    private let bubbleInset: CGFloat = 24

    var body: some View {
        HStack {
            Spacer(minLength: self.bubbleInset)
            self.content
                .frame(maxWidth: self.maxBubbleWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let base = VStack(alignment: .leading, spacing: OverlayLayout.toolContentSpacing) {
            switch self.mode {
            case .proposal(let proposal):
                self.proposalContent(proposal: proposal)
            case .executing(let label):
                self.executingContent(label: label)
            }
        }
        .padding(.horizontal, OverlayLayout.bubblePaddingHorizontal)
        .padding(.vertical, OverlayLayout.bubblePaddingVertical)

        if self.reduceTransparency {
            base
                .background(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.94)))
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6))
        } else {
            // Use .regular variant for full background adaptivity (light/dark)
            // Tint opacity lowered to reduce black outline artifacts
            base
                .glassEffect(.regular.tint(.white.opacity(0.04)), in: shape)
        }
    }

    private func proposalContent(proposal: ToolProposal) -> some View {
        VStack(alignment: .leading, spacing: OverlayLayout.toolContentSpacing) {
            HStack {
                Image(systemName: Self.iconForTool(proposal.toolName))
                    .foregroundColor(Self.colorForTool(proposal.toolName))
                    .accessibilityHidden(true)
                Text(Self.titleForTool(proposal.toolName))
                    .font(.headline)
            }

            Text(proposal.summary)
                .font(.body)

            if let details = proposal.details {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    NotificationCenter.default.post(name: .proposalDenied, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
                .focused(self.$cancelButtonFocused)
                .accessibilityLabel("Cancel action")
                .accessibilityHint("Cancels the proposed action")

                Spacer()

                Button("Confirm") {
                    NotificationCenter.default.post(name: .proposalConfirmed, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .focused(self.$confirmButtonFocused)
                .accessibilityLabel("Confirm action")
                .accessibilityHint("Confirms and executes the proposed action")
            }
        }
        .onAppear {
            self.confirmButtonFocused = true
        }
    }

    private func executingContent(label: String) -> some View {
        HStack(spacing: 8) {
            // Animated gear icon
            Image(systemName: "gearshape")
                .symbolEffect(.rotate, options: .repeating, isActive: !self.reduceMotion)
            Text(label)
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: - Tool-Specific Styling

    static func style(for toolName: String) -> ToolStyle {
        if toolName.contains("delete") {
            return .delete
        } else if toolName.contains("create") {
            return .create
        } else if toolName.contains("edit") {
            return .edit
        } else if toolName.contains("complete") {
            return .complete
        } else {
            return .unknown
        }
    }

    static func iconForTool(_ toolName: String) -> String {
        Self.icon(for: Self.style(for: toolName))
    }

    static func colorForTool(_ toolName: String) -> Color {
        Self.color(for: Self.style(for: toolName))
    }

    static func titleForTool(_ toolName: String) -> String {
        Self.title(for: Self.style(for: toolName))
    }

    static func icon(for style: ToolStyle) -> String {
        switch style {
        case .delete:
            return "trash.fill"
        case .create:
            return "plus.circle.fill"
        case .edit:
            return "pencil.circle.fill"
        case .complete:
            return "checkmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    static func color(for style: ToolStyle) -> Color {
        switch style {
        case .delete:
            return .red
        case .create:
            return .green
        case .edit:
            return .orange
        case .complete:
            return .green
        case .unknown:
            return .blue
        }
    }

    static func title(for style: ToolStyle) -> String {
        switch style {
        case .delete:
            return "Confirm Delete"
        case .create:
            return "Confirm Create"
        case .edit:
            return "Confirm Edit"
        case .complete:
            return "Confirm Complete"
        case .unknown:
            return "Confirm Action"
        }
    }
}
