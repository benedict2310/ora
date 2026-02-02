//
//  UpdatePreferencesView.swift
//  Ora
//
//  Preferences UI for Sparkle updates
//

import SwiftUI

struct UpdatePreferencesView: View {

    // MARK: - State

    @StateObject private var updateController: UpdateController

    // MARK: - Initialization

    init(updateController: UpdateController = .shared) {
        self._updateController = StateObject(wrappedValue: updateController)
    }

    // MARK: - Body

    var body: some View {
        Section {
            Toggle(isOn: self.$updateController.automaticallyChecksForUpdates) {
                VStack(alignment: .leading) {
                    Text("Automatic Updates")
                        .font(.headline)
                    Text("Check for new versions in the background")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Check Interval")
                        .font(.headline)
                    Spacer()
                }
                Picker("Check Interval", selection: self.$updateController.updateCheckInterval) {
                    ForEach(UpdateCheckInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .labelsHidden()
                .disabled(!self.updateController.automaticallyChecksForUpdates)
                Text("Sparkle uses this interval for automatic checks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Last Checked")
                        .font(.headline)
                    Text("Most recent successful check")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(self.lastCheckText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Private

    private var lastCheckText: String {
        guard let lastCheck = self.updateController.lastUpdateCheck else {
            return "Never"
        }
        return Self.dateFormatter.string(from: lastCheck)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
