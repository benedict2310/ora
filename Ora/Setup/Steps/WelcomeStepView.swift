//
//  WelcomeStepView.swift
//  Ora
//
//  Welcome step of setup
//

import SwiftUI

struct WelcomeStepView: View {
    let state: SetupState

    private var hotkeyDisplayString: String {
        HotkeyConfiguration.load().displayString
    }

    var body: some View {
        VStack(spacing: 24) {
            // App icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            // Welcome text
            Text("Welcome to Ora")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your private voice assistant that runs entirely on your Mac.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
                .frame(height: 20)

            // System info
            VStack(alignment: .leading, spacing: 12) {
                SystemInfoRow(
                    icon: "memorychip",
                    title: "System Memory",
                    value: "\(self.state.systemRAMGB) GB RAM"
                )

                SystemInfoRow(
                    icon: "cpu",
                    title: "Recommended Model",
                    value: self.state.recommendedModel
                )

                SystemInfoRow(
                    icon: "keyboard",
                    title: "Activation Hotkey",
                    value: self.hotkeyDisplayString
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            Spacer()

            // Privacy note
            Label("All processing happens on your device. No data is sent to the cloud.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct SystemInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: self.icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)

            Text(self.title)
                .foregroundColor(.secondary)

            Spacer()

            Text(self.value)
                .fontWeight(.medium)
        }
    }
}
