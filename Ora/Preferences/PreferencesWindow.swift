//
//  PreferencesWindow.swift
//  Ora
//
//  Main preferences window with tabbed interface
//

import SwiftUI

struct PreferencesWindow: View {
    @EnvironmentObject var coordinator: PreferencesCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $coordinator.selectedTab) {
                ForEach(PreferencesTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 80)
            .padding(.top, 12)
            .padding(.bottom, 16)

            // Content area
            Group {
                switch coordinator.selectedTab {
                case .general:
                    GeneralPreferencesView()
                case .providers:
                    ProviderPreferencesView()
                case .models:
                    ModelsPreferencesView()
                case .memory:
                    MemoryPreferencesView()
                case .permissions:
                    PermissionsPreferencesView()
                case .about:
                    AboutPreferencesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 550, minHeight: 450)
    }
}
