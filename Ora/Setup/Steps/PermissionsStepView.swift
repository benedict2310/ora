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
        VStack(alignment: .leading, spacing: 20) {
            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ora needs microphone access to listen. Calendar, Reminders, and Contacts are optional for actions.")
                .foregroundStyle(.secondary)

            GlassEffectContainer(spacing: 16) {
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
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if !self.permissionsState.requiredPermissionsGranted {
                Label("Microphone access is required to continue setup.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
                    .glassEffect(.regular.tint(Color.orange.opacity(0.18)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            self.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .permissionsStateDidChange)) { notification in
            // Read the state from the notification to avoid re-triggering refreshAll
            if let state = notification.object as? PermissionsState {
                self.permissionsState = state
                self.coordinator.updatePermissionsGranted(state.requiredPermissionsGranted)
                self.bringSetupToFrontIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh when returning from System Settings
            self.refreshPermissions()
            self.bringSetupToFrontIfNeeded()
        }
    }

    private func refreshPermissions() {
        Task {
            await PermissionsManager.shared.refreshAll()
            let state = await PermissionsManager.shared.state
            self.permissionsState = state
            self.coordinator.updatePermissionsGranted(state.requiredPermissionsGranted)
            self.bringSetupToFrontIfNeeded()
        }
    }

    private func bringSetupToFrontIfNeeded() {
        guard self.coordinator.isShowingSetup,
              self.coordinator.state.currentStep == .permissions else { return }
        self.coordinator.bringSetupToFront()
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
                            .foregroundStyle(.orange)
                            .cornerRadius(4)
                    }
                }

                Text(self.type.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status indicator or button
            if self.status.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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
