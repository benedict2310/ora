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
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
        .padding(.bottom, 8)
        .animation(self.reduceMotion ? nil : .bouncy(duration: 0.35), value: self.state)
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
        let cornerRadius = isIdle ? 999.0 : 20.0
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let base = HStack(spacing: 10) {
            content()
        }
        .foregroundStyle(Color.white.opacity(0.95))
        .padding(.horizontal, isIdle ? 14 : 16)
        .padding(.vertical, isIdle ? 9 : 12)
        .frame(maxWidth: isIdle ? nil : 420, alignment: .center)

        if self.reduceTransparency {
            base
                .background(shape.fill(Color.black.opacity(0.9)))
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
        } else {
            // Fix B: glassEffect must be LAST - apply shadow to outer container
            base
                .glassEffect(
                    .regular.tint(.black.opacity(0.9)),
                    in: shape
                )
                .glassEffectID("voiceInput", in: self.namespace)
                .applyGlassTransition(reduceMotion: self.reduceMotion)
                .compositingGroup()  // Flatten before shadow
                .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
        }
    }

    private func idleContent(label: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.cyan.opacity(0.9))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption.weight(.bold))
        }
    }

    private func activeContent(transcript: String?) -> some View {
        HStack(spacing: 10) {
            self.recordingIndicator
            if self.reduceMotion {
                Text(self.activeText(transcript: transcript))
                    .lineLimit(3)
            } else {
                Text(self.activeText(transcript: transcript))
                    .lineLimit(3)
                    .contentTransition(.interpolate)
            }
        }
    }

    private func activeText(transcript: String?) -> String {
        let trimmed = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Listening..." : trimmed
    }

    @ViewBuilder
    private var recordingIndicator: some View {
        let dot = Circle()
            .fill(Color.cyan.opacity(0.85))
            .frame(width: 10, height: 10)

        if self.reduceMotion {
            dot
        } else {
            dot.phaseAnimator([0.9, 1.1, 0.95, 1.05]) { view, phase in
                view
                    .scaleEffect(phase)
                    .shadow(color: .cyan.opacity(0.5), radius: 6)
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
