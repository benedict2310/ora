//
//  TextInputView.swift
//  Ora
//
//  Single-line text input control for silent interaction mode.
//

import AppKit
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let base = HStack(spacing: 10) {
            CursorEndTextField(
                text: self.$text,
                placeholder: "Type a message",
                onSubmit: { self.submitText() },
                onEscape: { self.onCancel() }
            )
            .frame(height: 20)
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

// MARK: - NSTextField Wrapper (cursor placement control)

private struct CursorEndTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = self.placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .callout)
        field.textColor = NSColor.white.withAlphaComponent(0.95)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = true
        field.stringValue = self.text

        // Become first responder with cursor at end
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.moveToEndOfDocument(nil)
        }

        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != self.text {
            field.stringValue = self.text
            // Keep cursor at end after programmatic text changes (e.g., clearing after submit)
            field.currentEditor()?.moveToEndOfDocument(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: CursorEndTextField

        init(parent: CursorEndTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            self.parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                self.parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                self.parent.onEscape()
                return true
            }
            return false
        }
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
