//
//  ReadyStepView.swift
//  Ora
//
//  Setup complete step - Conversation Mode instructions
//

import SwiftUI

struct ReadyStepView: View {
    private var hotkeyDisplayString: String {
        HotkeyConfiguration.load().displayString
    }

    var body: some View {
        VStack(spacing: 20) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    self.hotkeyCard
                    self.detailCard
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var hotkeyCard: some View {
        VStack(spacing: 16) {
            Text("Press")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(self.hotkeyDisplayString)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("and start talking")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detailCard: some View {
        VStack(spacing: 8) {
            Text("Ora will listen, respond, and can continue in conversation mode.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("You can change permissions, providers, and models anytime from the menu bar icon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Preview

#Preview {
    ReadyStepView()
        .frame(width: 500, height: 400)
        .padding()
}
