//
//  SkillsPreferencesView.swift
//  Ora
//
//  Preferences tab for managing the skills runtime.
//

import AppKit
import SwiftUI

struct SkillsPreferencesView: View {
    private struct ScriptTrustState: Sendable {
        let level: String
        let hashes: [String: String]
    }

    // MARK: - State

    @State private var skillsEnabled = true
    @State private var scriptsEnabled = true
    @State private var skills: [SkillMetadata] = []
    @State private var scriptTrust: [String: ScriptTrustState] = [:]
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

                Toggle(isOn: self.$scriptsEnabled) {
                    VStack(alignment: .leading) {
                        Text("Enable Script Execution")
                            .font(.headline)
                        Text("Allow skill scripts to run as child processes with your user permissions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: self.scriptsEnabled) { _, newValue in
                    PersistenceManager.shared.updateSettings { settings in
                        settings.scriptsEnabled = newValue
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
                                if skill.hasScripts {
                                    Text("Scripts")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                }
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

                            if skill.hasScripts {
                                self.scriptTrustSection(for: skill)
                            }
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
        self.scriptsEnabled = PersistenceManager.shared.settings.scriptsEnabled
        self.skills = await SkillStore.shared.list()
        await self.reloadTrustState()
    }

    private func rescanSkills() {
        self.isRescanning = true

        Task {
            await SkillStore.shared.rebuildIndex()
            let updated = await SkillStore.shared.list()
            await self.reloadTrustState(skills: updated)

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

    @ViewBuilder
    private func scriptTrustSection(for skill: SkillMetadata) -> some View {
        let trust = self.scriptTrust[skill.id]

        VStack(alignment: .leading, spacing: 4) {
            Text("Trust: \(trust?.level ?? "Untrusted")")
                .font(.caption)
                .foregroundColor(.secondary)

            if let hashes = trust?.hashes, !hashes.isEmpty {
                ForEach(hashes.keys.sorted(), id: \.self) { name in
                    Text("\(name): \(hashes[name]?.prefix(12) ?? "")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            if skill.source == .user {
                HStack {
                    Button("Trust") {
                        Task {
                            try? await ScriptTrustManager.shared.grantTrust(
                                skillID: skill.id,
                                skillRoot: skill.rootURL
                            )
                            await self.reloadTrustState()
                        }
                    }

                    Button("Revoke") {
                        Task {
                            await ScriptTrustManager.shared.revokeTrust(skillID: skill.id)
                            await self.reloadTrustState()
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(.top, 2)
    }

    private func reloadTrustState(skills: [SkillMetadata]? = nil) async {
        let currentSkills: [SkillMetadata]
        if let skills {
            currentSkills = skills
        } else {
            currentSkills = await SkillStore.shared.list()
        }
        var state: [String: ScriptTrustState] = [:]

        for skill in currentSkills where skill.hasScripts {
            if let status = try? await ScriptTrustManager.shared.status(for: skill) {
                state[skill.id] = ScriptTrustState(
                    level: status.level.rawValue.capitalized,
                    hashes: status.currentHashes
                )
            }
        }

        await MainActor.run {
            self.scriptTrust = state
        }
    }
}
