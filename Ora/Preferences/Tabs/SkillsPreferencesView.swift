//
//  SkillsPreferencesView.swift
//  Ora
//
//  Preferences tab for managing the skills runtime.
//

import AppKit
import SwiftUI

struct SkillsPreferencesView: View {

    // MARK: - State

    @State private var skillsEnabled = true
    @State private var skills: [SkillMetadata] = []
    @State private var isRescanning = false

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.$skillsEnabled) {
                    VStack(alignment: .leading) {
                        Text("Enable Skills")
                            .font(.headline)
                        Text("Allow optional workflow playbooks to guide tool orchestration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: self.skillsEnabled) { _, newValue in
                    PersistenceManager.shared.updateSettings { settings in
                        settings.skillsEnabled = newValue
                    }
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Installed Skills")
                            .font(.headline)
                        Text("Bundled and user-installed skills discovered at runtime")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(self.skills.count)")
                        .foregroundColor(.secondary)
                }

                if self.skills.isEmpty {
                    Text("No skills found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(self.skills, id: \.id) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(skill.name)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(skill.source.rawValue.capitalized)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(skill.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(skill.id)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                HStack {
                    if self.isRescanning {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }

                    Button("Rescan Skills") {
                        self.rescanSkills()
                    }
                    .disabled(self.isRescanning)

                    Spacer()

                    Button("Open Skills Folder") {
                        self.openUserSkillsFolder()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await self.loadState()
        }
    }

    // MARK: - Private

    private func loadState() async {
        self.skillsEnabled = PersistenceManager.shared.settings.skillsEnabled
        self.skills = await SkillStore.shared.list()
    }

    private func rescanSkills() {
        self.isRescanning = true

        Task {
            await SkillStore.shared.rebuildIndex()
            let updated = await SkillStore.shared.list()

            await MainActor.run {
                self.skills = updated
                self.isRescanning = false
            }
        }
    }

    private func openUserSkillsFolder() {
        Task {
            let folderURL = await SkillStore.shared.userSkillsFolderURL()
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            await MainActor.run {
                _ = NSWorkspace.shared.open(folderURL)
            }
        }
    }
}
