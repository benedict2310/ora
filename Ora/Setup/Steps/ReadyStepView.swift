//
//  ReadyStepView.swift
//  Ora
//
//  Setup complete step
//

import SwiftUI

struct ReadyStepView: View {
    private var hotkeyDisplayString: String {
        HotkeyConfiguration.load().displayString
    }

    var body: some View {
        VStack(spacing: 24) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ora is ready to assist you.")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()
                .frame(height: 20)

            // Hotkey tutorial
            VStack(spacing: 16) {
                Text("How to Use Ora")
                    .font(.headline)

                HStack(spacing: 20) {
                    TutorialStep(
                        number: 1,
                        icon: "keyboard",
                        title: "Press & Hold",
                        description: self.hotkeyDisplayString
                    )

                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)

                    TutorialStep(
                        number: 2,
                        icon: "waveform",
                        title: "Speak",
                        description: "Say your request"
                    )

                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)

                    TutorialStep(
                        number: 3,
                        icon: "hand.raised",
                        title: "Release",
                        description: "Let go to send"
                    )
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            Spacer()

            Text("You can change settings anytime from the menu bar icon.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct TutorialStep: View {
    let number: Int
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 50, height: 50)

                Image(systemName: self.icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }

            Text(self.title)
                .font(.caption)
                .fontWeight(.medium)

            Text(self.description)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
