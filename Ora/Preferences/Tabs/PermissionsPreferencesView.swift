//
//  PermissionsPreferencesView.swift
//  Ora
//
//  Permissions status tab
//

import SwiftUI

struct PermissionsPreferencesView: View {

    // MARK: - State

    @State private var permissionsState = PermissionsState()

    // MARK: - Body

    var body: some View {
        Form {
            // Required permissions
            Section {
                ForEach(PermissionType.allCases.filter { $0.isRequired }, id: \.self) { permission in
                    PermissionRowView(
                        type: permission,
                        status: permissionsState[permission]
                    )
                }
            } header: {
                Text("Required")
            }

            // Optional permissions
            Section {
                ForEach(PermissionType.allCases.filter { !$0.isRequired }, id: \.self) { permission in
                    PermissionRowView(
                        type: permission,
                        status: permissionsState[permission]
                    )
                }
            } header: {
                Text("Optional")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording")
                        .fontWeight(.medium)
                    Text("Needed only when you use screenshot attachments in the overlay.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Open Screen Recording Settings") {
                    Task { @MainActor in
                        ScreenshotCaptureService.shared.openScreenRecordingSettings()
                    }
                }
                .controlSize(.small)
            } header: {
                Text("Screenshot Attachments")
            }

            Section {
                Button("Refresh Status") {
                    self.refreshPermissions()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            self.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .permissionsStateDidChange)) { notification in
            if let state = notification.object as? PermissionsState {
                permissionsState = state
            }
        }
    }

    // MARK: - Private Methods

    private func refreshPermissions() {
        Task {
            await PermissionsManager.shared.refreshAll()
            permissionsState = await PermissionsManager.shared.state
        }
    }
}

// MARK: - Permission Row View

struct PermissionRowView: View {

    let type: PermissionType
    let status: PermissionStatus

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(type.displayName)
                    .fontWeight(.medium)

                Text(type.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status
            HStack(spacing: 8) {
                self.statusIcon

                if !status.isGranted {
                    Button("Open Settings") {
                        Task { @MainActor in
                            await PermissionsManager.shared.openSettings(for: type)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .notDetermined:
            Image(systemName: "questionmark.circle.fill")
                .foregroundColor(.orange)
        case .restricted:
            Image(systemName: "lock.circle.fill")
                .foregroundColor(.gray)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .foregroundColor(.secondary)
        }
    }
}
