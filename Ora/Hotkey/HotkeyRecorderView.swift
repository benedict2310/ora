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
                        .fill(isRecording ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )

            // Change/Cancel button
            if isRecording {
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
            .disabled(configuration == HotkeyConfiguration.defaultHotkey)
        }
        .alert("Hotkey Conflict", isPresented: $showConflictWarning) {
            Button("OK") {}
        } message: {
            Text("This hotkey may conflict with another application or system shortcut.")
        }
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true

        // Create local event monitor for key events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                // Ignore modifier-only presses
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

                // Check for potential conflicts (simplified check)
                if self.checkForConflicts(newConfig) {
                    showConflictWarning = true
                }

                // Apply the new configuration
                configuration = newConfig
                configuration.save()
                self.stopRecording()

                return nil // Consume the event
            }

            return event
        }
    }

    private func stopRecording() {
        isRecording = false

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func resetToDefault() {
        configuration = HotkeyConfiguration.defaultHotkey
        configuration.save()
    }

    private func checkForConflicts(_ config: HotkeyConfiguration) -> Bool {
        // Check common system shortcuts
        // This is a simplified check - real implementation would be more thorough

        // Cmd+Q (Quit)
        if config.keyCode == UInt16(kVK_ANSI_Q) && config.modifiers == UInt32(cmdKey) {
            return true
        }

        // Cmd+W (Close Window)
        if config.keyCode == UInt16(kVK_ANSI_W) && config.modifiers == UInt32(cmdKey) {
            return true
        }

        // Cmd+Tab (App Switcher)
        if config.keyCode == UInt16(kVK_Tab) && config.modifiers == UInt32(cmdKey) {
            return true
        }

        // Cmd+Space (Spotlight) - common conflict
        if config.keyCode == UInt16(kVK_Space) && config.modifiers == UInt32(cmdKey) {
            return true
        }

        return false
    }
}
