//
//  HotkeyRecorderView.swift
//  Ora
//
//  SwiftUI view for recording hotkey combinations
//

import SwiftUI
import Carbon.HIToolbox

struct HotkeyRecorderView: View {

    // MARK: - Properties

    @Binding var configuration: HotkeyConfiguration
    @State private var isRecording = false
    @State private var showConflictWarning = false
    @State private var eventMonitor: Any?

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Display current hotkey
            Text(configuration.displayString)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(self.isRecording ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(self.isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )

            // Change/Cancel button
            if self.isRecording {
                Button("Cancel") {
                    self.stopRecording()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Change") {
                    self.startRecording()
                }
                .buttonStyle(.bordered)
            }

            // Reset button
            Button {
                self.resetToDefault()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to default (⌥Space)")
            .disabled(self.configuration == HotkeyConfiguration.defaultHotkey)
        }
        .alert("Hotkey Conflict", isPresented: self.$showConflictWarning) {
            Button("OK") {}
        } message: {
            Text("This hotkey may conflict with another application or system shortcut.")
        }
    }

    // MARK: - Recording

    private func startRecording() {
        self.isRecording = true

        // Temporarily stop the hotkey manager while recording
        HotkeyManager.shared.stop()

        // Create local event monitor for key events
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                let keyCode = event.keyCode

                // Get modifier flags
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var carbonModifiers: UInt32 = 0

                if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
                if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
                if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
                if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }

                // Require at least one modifier
                guard carbonModifiers != 0 else {
                    return event
                }

                // Escape cancels recording
                if keyCode == UInt16(kVK_Escape) {
                    self.stopRecording()
                    return nil
                }

                // Create new configuration
                let newConfig = HotkeyConfiguration(keyCode: keyCode, modifiers: carbonModifiers)

                // Check for potential conflicts using HotkeyManager
                if HotkeyManager.shared.checkForConflicts(newConfig) {
                    self.showConflictWarning = true
                }

                // Apply the new configuration via HotkeyManager
                self.configuration = newConfig
                HotkeyManager.shared.setHotkey(newConfig)
                self.stopRecording()

                return nil // Consume the event
            }

            return event
        }
    }

    private func stopRecording() {
        self.isRecording = false

        if let monitor = self.eventMonitor {
            NSEvent.removeMonitor(monitor)
            self.eventMonitor = nil
        }

        // Restart the hotkey manager
        HotkeyManager.shared.start()
    }

    private func resetToDefault() {
        self.configuration = HotkeyConfiguration.defaultHotkey
        HotkeyManager.shared.resetToDefault()
    }
}
