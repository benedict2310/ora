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
                            .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: voiceOutputEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "com.ora.voiceOutputEnabled")
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
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: conversationModeEnabled) { _, newValue in
                    PersistenceManager.shared.updateSettings { settings in
                        settings.conversationModeEnabled = newValue
                    }
                }
            }

            // Default Calendar Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Calendar")
                        .font(.headline)
                    Text("Calendar used for new events")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if calendars.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No calendars available. Grant calendar access in Permissions.")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                            UserDefaults.standard.set(newValue, forKey: "com.ora.defaultCalendarID")
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
        // Voice output defaults to true if not set
        if UserDefaults.standard.object(forKey: "com.ora.voiceOutputEnabled") == nil {
            voiceOutputEnabled = true
        } else {
            voiceOutputEnabled = UserDefaults.standard.bool(forKey: "com.ora.voiceOutputEnabled")
        }

        // Conversation mode from SwiftData settings (AC-6: default true)
        conversationModeEnabled = PersistenceManager.shared.settings.conversationModeEnabled

        selectedCalendarID = UserDefaults.standard.string(forKey: "com.ora.defaultCalendarID") ?? ""
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
