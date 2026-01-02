//
//  PermissionsStepView.swift
//  Ora
//
//  Permissions request step
//

import SwiftUI

struct PermissionsStepView: View {
    @ObservedObject var coordinator: SetupCoordinator
    @State private var permissionsState = PermissionsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ora needs a few permissions to work properly.")
                .foregroundColor(.secondary)

            VStack(spacing: 16) {
                // Required permissions
                Text("Required")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                PermissionRow(
                    type: .microphone,
                    status: self.permissionsState.microphone,
                    onRequest: { await self.coordinator.requestPermission(.microphone) }
                )

                Divider()

                // Optional permissions
                Text("Optional")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                PermissionRow(
                    type: .calendar,
                    status: self.permissionsState.calendar,
                    onRequest: { await self.coordinator.requestPermission(.calendar) }
                )

                PermissionRow(
                    type: .reminders,
                    status: self.permissionsState.reminders,
                    onRequest: { await self.coordinator.requestPermission(.reminders) }
                )

                PermissionRow(
                    type: .contacts,
                    status: self.permissionsState.contacts,
                    onRequest: { await self.coordinator.requestPermission(.contacts) }
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            Spacer()

            if !self.permissionsState.requiredPermissionsGranted {
                Label("Microphone permission is required to continue.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            self.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .permissionsStateDidChange)) { notification in
            // Read the state from the notification to avoid re-triggering refreshAll
            if let state = notification.object as? PermissionsState {
                self.permissionsState = state
                self.coordinator.updatePermissionsGranted(state.requiredPermissionsGranted)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh when returning from System Settings
            self.refreshPermissions()
        }
    }

    private func refreshPermissions() {
        Task {
            await PermissionsManager.shared.refreshAll()
            let state = await PermissionsManager.shared.state
            self.permissionsState = state
            self.coordinator.updatePermissionsGranted(state.requiredPermissionsGranted)
        }
    }
}

struct PermissionRow: View {
    let type: PermissionType
    let status: PermissionStatus
    let onRequest: () async -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(self.type.displayName)
                        .fontWeight(.medium)

                    if self.type.isRequired {
                        Text("Required")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }

                Text(self.type.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status indicator or button
            if self.status.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else if self.status == .denied {
                Button("Open Settings") {
                    Task { @MainActor in
                        await PermissionsManager.shared.openSettings(for: self.type)
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button("Grant") {
                    Task { await self.onRequest() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 8)
    }
}
