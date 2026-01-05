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
        VStack(spacing: 24) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer()
                .frame(height: 16)

            // Hotkey card
            VStack(spacing: 20) {
                Text("Press")
                    .font(.title3)
                    .foregroundColor(.secondary)

                // Hotkey display in glass card
                Text(self.hotkeyDisplayString)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

                Text("and start talking")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer()
                .frame(height: 8)

            // Conversation mode description
            Text("Ora will listen, respond, and keep the conversation going.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            // Tip
            Text("You can change settings anytime from the menu bar icon.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    ReadyStepView()
        .frame(width: 500, height: 400)
        .padding()
}
