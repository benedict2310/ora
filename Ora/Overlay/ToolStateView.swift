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
            base
                .glassEffect(.regular.tint(.white.opacity(0.12)), in: shape)
        }
    }

    private func proposalContent(proposal: ToolProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .accessibilityHidden(true)
                Text("Confirm Action")
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
}
