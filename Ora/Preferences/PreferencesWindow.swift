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
        TabView(selection: $coordinator.selectedTab) {
            GeneralPreferencesView()
                .tabItem {
                    Label(PreferencesTab.general.title, systemImage: PreferencesTab.general.icon)
                }
                .tag(PreferencesTab.general)

            ModelsPreferencesView()
                .tabItem {
                    Label(PreferencesTab.models.title, systemImage: PreferencesTab.models.icon)
                }
                .tag(PreferencesTab.models)

            PermissionsPreferencesView()
                .tabItem {
                    Label(PreferencesTab.permissions.title, systemImage: PreferencesTab.permissions.icon)
                }
                .tag(PreferencesTab.permissions)

            AboutPreferencesView()
                .tabItem {
                    Label(PreferencesTab.about.title, systemImage: PreferencesTab.about.icon)
                }
                .tag(PreferencesTab.about)
        }
        .frame(minWidth: 550, minHeight: 450)
    }
}
