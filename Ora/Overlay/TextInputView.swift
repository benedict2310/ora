//
//  TextInputView.swift
//  Ora
//
//  Single-line text input control for silent interaction mode.
//

import SwiftUI

struct TextInputCommandHandler {
    static func consumeSubmission(from text: inout String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return nil
        }

        text = ""
        return trimmedText
    }

    static func handleEscape(_ onCancel: () -> Void) {
        onCancel()
    }
}

struct TextInputView: View {
    @Binding var text: String
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let namespace: Namespace.ID
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    let onPasteImage: () -> Void
    let onChooseImageFile: () -> Void
    let onCaptureScreenshot: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let base = HStack(spacing: 10) {
            TextField("Type a message", text: self.$text)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .focused(self.$isFocused)
                .onSubmit {
                    self.submitText()
                }
            self.attachmentActions
        }
        .foregroundStyle(Color.white.opacity(0.95))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: OverlayLayout.assistantBubbleMaxWidth, alignment: .leading)

        Group {
            if self.reduceTransparency {
                base
                    .background(shape.fill(Color.black.opacity(0.88)))
                    .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
            } else {
                base
                    .glassEffect(
                        .regular.tint(.black.opacity(0.88)).interactive(true),
                        in: shape
                    )
                    .glassEffectID("voiceInput", in: self.namespace)
                    .applyTextInputGlassTransition(reduceMotion: self.reduceMotion)
                    .compositingGroup()
                    .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .center)
        .padding(.bottom, OverlayLayout.voiceInputBottomPadding)
        .onAppear {
            self.isFocused = true
        }
        .onExitCommand {
            TextInputCommandHandler.handleEscape(self.onCancel)
        }
    }

    private func submitText() {
        var draftText = self.text
        guard let submittedText = TextInputCommandHandler.consumeSubmission(from: &draftText) else {
            return
        }

        self.text = draftText
        self.onSubmit(submittedText)
    }

    private var attachmentActions: some View {
        HStack(spacing: 6) {
            self.attachmentActionButton(
                icon: "doc.on.clipboard",
                accessibilityLabel: "Paste image from clipboard",
                action: self.onPasteImage
            )
            self.attachmentActionButton(
                icon: "photo",
                accessibilityLabel: "Choose image file",
                action: self.onChooseImageFile
            )
            self.attachmentActionButton(
                icon: "camera.viewfinder",
                accessibilityLabel: "Capture screenshot",
                action: self.onCaptureScreenshot
            )
        }
    }

    private func attachmentActionButton(
        icon: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.82))
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension View {
    @ViewBuilder
    func applyTextInputGlassTransition(reduceMotion: Bool) -> some View {
        if reduceMotion {
            self
        } else {
            self.glassEffectTransition(.matchedGeometry)
        }
    }
}
