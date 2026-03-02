//
//  SkillAuthoringConfirmationSheet.swift
//  Ora
//
//  Dedicated modal confirmation UI for skill authoring operations.
//

import SwiftUI

struct SkillAuthoringConfirmationSheet: View {
    let proposal: ToolProposal
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(self.proposal.title ?? "Confirm Skill Change")
                .font(.title3.weight(.semibold))

            Text(self.proposal.summary)
                .font(.body)
                .foregroundStyle(.secondary)

            self.sheetContent

            HStack {
                Spacer()

                Button(self.proposal.cancelLabel ?? "Cancel") {
                    self.onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(self.proposal.confirmLabel ?? "Confirm") {
                    self.onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520, alignment: .topLeading)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch self.proposal.presentation {
        case .inline:
            if let details = self.proposal.details {
                Text(details)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

        case .skillDocumentPreview(let content):
            ScrollView {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

        case .skillDeletion(let name, let description):
            VStack(alignment: .leading, spacing: 12) {
                Text(name)
                    .font(.headline)

                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
}
