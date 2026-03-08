//
//  GeneralPreferencesView.swift
//  Ora
//
//  General settings tab
//

import SwiftUI
import EventKit

struct GeneralPreferencesView: View {

    // MARK: - State

    @State private var hotkeyConfig = HotkeyConfiguration.load()
    @State private var voiceOutputEnabled = true
    @State private var conversationModeEnabled = true
    @State private var silenceTimeout: Double = 1.0
    @State private var selectedCalendarID: String = ""
    @State private var calendars: [EKCalendar] = []

    // MARK: - Body

    var body: some View {
        Form {
            // Hotkey Section
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Activation Hotkey")
                            .font(.headline)
                        Text("Press and hold to speak, release to send")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HotkeyRecorderView(configuration: $hotkeyConfig)
                }
            }

            // Voice Output Section
            Section {
                Toggle(isOn: $voiceOutputEnabled) {
                    VStack(alignment: .leading) {
                        Text("Voice Output")
                            .font(.headline)
                        Text("Enable text-to-speech responses")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: voiceOutputEnabled) { _, newValue in
                    UserDefaults.standard.oraVoiceOutputEnabled = newValue
                }
            }

            // Conversation Mode Section (AC-5)
            Section {
                Toggle(isOn: $conversationModeEnabled) {
                    VStack(alignment: .leading) {
                        Text("Conversation Mode")
                            .font(.headline)
                        Text("Auto-submit after silence, continue listening after response")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: conversationModeEnabled) { _, newValue in
                    PersistenceManager.shared.updateSettings { settings in
                        settings.conversationModeEnabled = newValue
                    }
                }

                // Silence timeout slider (only relevant when conversation mode is on)
                if conversationModeEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Silence Timeout")
                                .font(.headline)
                            Spacer()
                            Text(self.formatTimeout(silenceTimeout))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text("Time to wait after speech stops before auto-submitting")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("0.5s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $silenceTimeout, in: 0.5...2.0, step: 0.1)
                                .onChange(of: silenceTimeout) { _, newValue in
                                    PersistenceManager.shared.updateSettings { settings in
                                        settings.silenceTimeout = newValue
                                    }
                                }
                            Text("2.0s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
            }

            // Updates Section
            UpdatePreferencesView()

            // Default Calendar Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Calendar")
                        .font(.headline)
                    Text("Calendar used for new events")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if calendars.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("No calendars available. Grant calendar access in Permissions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("", selection: $selectedCalendarID) {
                            Text("Default").tag("")
                            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                                HStack {
                                    Circle()
                                        .fill(Color(cgColor: calendar.cgColor ?? CGColor.black))
                                        .frame(width: 10, height: 10)
                                    Text(calendar.title)
                                }
                                .tag(calendar.calendarIdentifier)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedCalendarID) { _, newValue in
                            UserDefaults.standard.oraDefaultCalendarID = newValue
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            self.loadSettings()
            self.loadCalendars()
        }
    }

    // MARK: - Private Methods

    private func loadSettings() {
        voiceOutputEnabled = UserDefaults.standard.oraVoiceOutputEnabled

        // Conversation mode from SwiftData settings (AC-6: default true)
        conversationModeEnabled = PersistenceManager.shared.settings.conversationModeEnabled

        // Silence timeout from SwiftData settings (default 1.0s)
        silenceTimeout = PersistenceManager.shared.settings.silenceTimeout

        selectedCalendarID = UserDefaults.standard.oraDefaultCalendarID
    }

    private func formatTimeout(_ value: Double) -> String {
        return String(format: "%.1fs", value)
    }

    private func loadCalendars() {
        let store = EKEventStore()

        // Check authorization first
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            calendars = store.calendars(for: .event).filter { $0.allowsContentModifications }
        default:
            calendars = []
        }
    }
}
