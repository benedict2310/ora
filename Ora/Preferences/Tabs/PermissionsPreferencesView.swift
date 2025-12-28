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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Permissions")
                    .font(.headline)

                Text("Ora needs these permissions to function properly.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    ForEach(PermissionType.allCases, id: \.self) { permission in
                        PermissionRowView(
                            type: permission,
                            status: permissionsState[permission]
                        )
                    }
                }

                Button("Refresh Status") {
                    self.refreshPermissions()
                }
                .buttonStyle(.glass)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                HStack {
                    Text(type.displayName)
                        .fontWeight(.medium)

                    if type.isRequired {
                        Text("Required")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }

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
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
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
