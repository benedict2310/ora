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
        let base = VStack(alignment: .leading, spacing: 12) {
            switch self.mode {
            case .proposal(let proposal):
                self.proposalContent(proposal: proposal)
            case .executing(let label):
                self.executingContent(label: label)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if self.reduceTransparency {
            base
                .background(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.94)))
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6))
        } else {
            // Use .clear variant to reduce black outline artifacts when nested in GlassEffectContainer
            base
                .glassEffect(.clear.tint(.white.opacity(0.15)), in: shape)
        }
    }

    private func proposalContent(proposal: ToolProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: self.iconForTool(proposal.toolName))
                    .foregroundColor(self.colorForTool(proposal.toolName))
                    .accessibilityHidden(true)
                Text(self.titleForTool(proposal.toolName))
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
            if self.reduceMotion {
                Image(systemName: "gearshape")
                    .font(.caption)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tool-Specific Styling

    private func iconForTool(_ toolName: String) -> String {
        if toolName.contains("delete") {
            return "trash.fill"
        } else if toolName.contains("create") {
            return "plus.circle.fill"
        } else if toolName.contains("edit") {
            return "pencil.circle.fill"
        } else if toolName.contains("complete") {
            return "checkmark.circle.fill"
        } else {
            return "questionmark.circle.fill"
        }
    }

    private func colorForTool(_ toolName: String) -> Color {
        if toolName.contains("delete") {
            return .red
        } else if toolName.contains("create") {
            return .green
        } else if toolName.contains("edit") {
            return .orange
        } else if toolName.contains("complete") {
            return .green
        } else {
            return .blue
        }
    }

    private func titleForTool(_ toolName: String) -> String {
        if toolName.contains("delete") {
            return "Confirm Delete"
        } else if toolName.contains("create") {
            return "Confirm Create"
        } else if toolName.contains("edit") {
            return "Confirm Edit"
        } else if toolName.contains("complete") {
            return "Confirm Complete"
        } else {
            return "Confirm Action"
        }
    }
}
