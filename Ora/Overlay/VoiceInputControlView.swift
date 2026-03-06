//
//  VoiceInputControlView.swift
//  Ora
//
//  Voice input control for the overlay
//

import SwiftUI

struct VoiceInputControlView: View {
    enum State: Equatable {
        case idle(label: String)
        case active(transcript: String?)
    }

    let state: State
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let namespace: Namespace.ID
    let onPasteImage: () -> Void
    let onChooseImageFile: () -> Void
    let onCaptureScreenshot: () -> Void

    var body: some View {
        let isIdle = self.isIdle
        return self.voiceInputShell(isIdle: isIdle) {
            switch self.state {
            case .idle(let label):
                self.idleContent(label: label)
            case .active(let transcript):
                self.activeContent(transcript: transcript)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .center)
        .padding(.bottom, OverlayLayout.voiceInputBottomPadding)
        .animation(self.reduceMotion ? nil : .bouncy(duration: 0.3), value: self.state)
    }

    private var isIdle: Bool {
        if case .idle = self.state {
            return true
        }
        return false
    }

    @ViewBuilder
    private func voiceInputShell(
        isIdle: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let cornerRadius = isIdle ? 999.0 : 18.0
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let base = HStack(spacing: 8) {
            content()
            self.attachmentActions
        }
        .foregroundStyle(Color.white.opacity(0.95))
        .padding(.horizontal, isIdle ? 12 : 14)
        .padding(.vertical, isIdle ? 8 : 10)
        .frame(maxWidth: isIdle ? nil : OverlayLayout.assistantBubbleMaxWidth, alignment: .center)

        if self.reduceTransparency {
            base
                .background(shape.fill(Color.black.opacity(0.88)))
                .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
        } else {
            // glassEffect must be LAST - apply shadow to outer container
            base
                .glassEffect(
                    .regular.tint(.black.opacity(0.88)),
                    in: shape
                )
                .glassEffectID("voiceInput", in: self.namespace)
                .applyGlassTransition(reduceMotion: self.reduceMotion)
                .compositingGroup()  // Flatten before shadow
                .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
        }
    }

    private func idleContent(label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.cyan.opacity(0.85))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
    }

    private func activeContent(transcript: String?) -> some View {
        HStack(spacing: 8) {
            self.recordingIndicator
            if self.reduceMotion {
                Text(self.activeText(transcript: transcript))
                    .font(.callout)
                    .lineLimit(3)
            } else {
                Text(self.activeText(transcript: transcript))
                    .font(.callout)
                    .lineLimit(3)
                    .contentTransition(.interpolate)
            }
        }
    }

    private func activeText(transcript: String?) -> String {
        let trimmed = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Listening…" : trimmed
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

    @ViewBuilder
    private var recordingIndicator: some View {
        let dot = Circle()
            .fill(Color.cyan.opacity(0.85))
            .frame(width: 8, height: 8)

        if self.reduceMotion {
            dot
        } else {
            dot.phaseAnimator([0.9, 1.1, 0.95, 1.05]) { view, phase in
                view
                    .scaleEffect(phase)
                    .shadow(color: .cyan.opacity(0.4), radius: 4)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func applyGlassTransition(reduceMotion: Bool) -> some View {
        if reduceMotion {
            self
        } else {
            self.glassEffectTransition(.matchedGeometry)
        }
    }
}
