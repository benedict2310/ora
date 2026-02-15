//
//  MemoryPreferencesView.swift
//  Ora
//
//  Memory management panel in Preferences.
//

import SwiftUI

struct MemoryPreferencesView: View {

    // MARK: - State

    @State private var stats = MemoryStats()
    @State private var isReindexing = false

    // MARK: - Body

    var body: some View {
        Form {
            // Memory Folder Section
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Memory Folder")
                            .font(.headline)
                        Text("User-editable memory and session summaries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Open in Finder") {
                        self.openMemoryFolder()
                    }
                }
            }

            // Stats Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Memory Stats")
                        .font(.headline)

                    HStack {
                        Label("Memory entries", systemImage: "brain")
                        Spacer()
                        Text("\(self.stats.memoryEntryCount)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("Session summaries", systemImage: "doc.text")
                        Spacer()
                        Text("\(self.stats.summaryFileCount)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("Index size", systemImage: "externaldrive")
                        Spacer()
                        Text(self.stats.formattedIndexSize)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Re-index Section
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Search Index")
                            .font(.headline)
                        Text("Rebuild the memory search index")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if self.isReindexing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }

                    Button("Re-index Now") {
                        self.rebuildIndex()
                    }
                    .disabled(self.isReindexing)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            self.stats = Self.loadStats()
        }
    }

    // MARK: - Actions

    private func openMemoryFolder() {
        let memoryDirectory = MemoryFileManager().memoryDirectory
        NSWorkspace.shared.open(memoryDirectory)
    }

    private func rebuildIndex() {
        self.isReindexing = true

        Task {
            await MemoryIndex.shared.rebuild()

            await MainActor.run {
                self.stats = Self.loadStats()
                self.isReindexing = false
            }
        }
    }

    // MARK: - Stats

    private static func loadStats() -> MemoryStats {
        let manager = MemoryFileManager()
        let fileManager = FileManager.default

        // Count memory entries (lines starting with "- " in MEMORY.md)
        var entryCount = 0
        if let content = try? String(contentsOf: manager.memoryFileURL, encoding: .utf8) {
            entryCount = content.components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
                .count
        }

        // Count summary files
        var summaryCount = 0
        if let files = try? fileManager.contentsOfDirectory(
            at: manager.summariesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            summaryCount = files.filter { $0.pathExtension.lowercased() == "md" }.count
        }

        // Index file size
        let indexURL = manager.memoryDirectory.appendingPathComponent(".index.sqlite", isDirectory: false)
        var indexBytes: Int64 = 0
        if let attrs = try? fileManager.attributesOfItem(atPath: indexURL.path),
           let size = attrs[.size] as? Int64 {
            indexBytes = size
        }

        return MemoryStats(
            memoryEntryCount: entryCount,
            summaryFileCount: summaryCount,
            indexSizeBytes: indexBytes
        )
    }
}

// MARK: - MemoryStats

private struct MemoryStats {
    var memoryEntryCount: Int = 0
    var summaryFileCount: Int = 0
    var indexSizeBytes: Int64 = 0

    var formattedIndexSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self.indexSizeBytes)
    }
}
