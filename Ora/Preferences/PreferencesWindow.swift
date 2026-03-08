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
            Tab("General", systemImage: "gear", value: PreferencesTab.general) {
                GeneralPreferencesView()
            }
            Tab("Skills", systemImage: "sparkles", value: PreferencesTab.skills) {
                SkillsPreferencesView()
            }
            Tab("Providers", systemImage: "icloud", value: PreferencesTab.providers) {
                ProviderPreferencesView()
            }
            Tab("Models", systemImage: "cpu", value: PreferencesTab.models) {
                ModelsPreferencesView()
            }
            Tab("Memory", systemImage: "brain", value: PreferencesTab.memory) {
                MemoryPreferencesView()
            }
            Tab("Permissions", systemImage: "lock.shield", value: PreferencesTab.permissions) {
                PermissionsPreferencesView()
            }
            Tab("About", systemImage: "info.circle", value: PreferencesTab.about) {
                AboutPreferencesView()
            }
        }
        .frame(minWidth: 550, minHeight: 450)
    }
}
