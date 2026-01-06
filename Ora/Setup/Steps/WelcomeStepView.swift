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
            VStack(spacing: 12) {
                // App icon
                Image(nsImage: AppIcon.image)
                    .resizable()
                    .frame(width: 80, height: 80)

                // Welcome text
                Text("Welcome to Ora")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Your private voice assistant that runs entirely on your Mac.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    self.systemInfoCard
                    self.privacyCard
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var systemInfoCard: some View {
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
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var privacyCard: some View {
        Label("All processing happens on your device. No data is sent to the cloud.", systemImage: "lock.shield")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
