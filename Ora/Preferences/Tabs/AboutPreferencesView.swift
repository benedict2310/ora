//
//  AboutPreferencesView.swift
//  Ora
//
//  About and audit log tab
//

import SwiftUI

struct AboutPreferencesView: View {

    // MARK: - State

    @State private var showAuditLog = false

    // MARK: - Body

    var body: some View {
        Form {
            // App Info Section
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(nsImage: AppIcon.image)
                            .resizable()
                            .frame(width: 64, height: 64)

                        Text("Ora")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Version \(self.appVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            // Description Section
            Section {
                Text("A privacy-first voice assistant that runs entirely on your Mac.")
                    .foregroundColor(.secondary)
            }

            // Actions Section
            Section {
                Button {
                    showAuditLog = true
                } label: {
                    Label("View Audit Log", systemImage: "list.bullet.clipboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    if let url = URL(string: "https://github.com/benedict2310/ora") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("GitHub", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            // Privacy Section
            Section {
                Label("All processing happens on your device.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAuditLog) {
            AuditLogView()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

// MARK: - Audit Log View

struct AuditLogView: View {

    // MARK: - State

    @Environment(\.dismiss) var dismiss
    @State private var entries: [AuditLogEntry] = []
    @State private var selectedFilter: AuditFilter = .all
    @State private var isLoading = true
    @State private var showClearConfirmation = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Audit Log")
                    .font(.headline)

                Spacer()

                // Filter picker
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(AuditFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            // Log content
            if isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No entries")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List(filteredEntries) { entry in
                    AuditLogEntryRow(entry: entry)
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            HStack {
                Text("\(filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Export...") {
                    self.exportLog()
                }

                Button("Clear Log", role: .destructive) {
                    showClearConfirmation = true
                }
            }
            .padding()
        }
        .frame(width: 600, height: 500)
        .onAppear {
            self.loadEntries()
        }
        .onChange(of: selectedFilter) { _, _ in
            // Filter is applied in computed property
        }
        .alert("Clear Audit Log?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                self.clearLog()
            }
        } message: {
            Text("This will permanently delete all audit log entries. This action cannot be undone.")
        }
    }

    // MARK: - Computed Properties

    private var filteredEntries: [AuditLogEntry] {
        Self.filteredEntries(entries, filter: selectedFilter)
    }

    static func filteredEntries(_ entries: [AuditLogEntry], filter: AuditFilter) -> [AuditLogEntry] {
        switch filter {
        case .all:
            return entries
        case .tools:
            return entries.filter { $0.category == .toolExecution }
        case .errors:
            return entries.filter { $0.category == .error }
        case .confirmations:
            return entries.filter { $0.category == .confirmation }
        }
    }

    // MARK: - Private Methods

    private func loadEntries() {
        isLoading = true
        Task {
            entries = await AuditLogger.shared.fetchEntries(limit: 500)
            isLoading = false
        }
    }

    private func clearLog() {
        Task {
            await AuditLogger.shared.clearAll()
            entries = []
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ora-audit-log-\(self.formattedDate()).json"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task {
                    await AuditLogger.shared.exportTo(url: url)
                }
            }
        }
    }

    private func formattedDate() -> String {
        Self.formattedDate(for: Date())
    }

    static func formattedDate(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Audit Filter

enum AuditFilter: String, CaseIterable {
    case all
    case tools
    case errors
    case confirmations

    var displayName: String {
        switch self {
        case .all: return "All"
        case .tools: return "Tools"
        case .errors: return "Errors"
        case .confirmations: return "Confirmations"
        }
    }
}

// MARK: - Audit Log Entry Row

struct AuditLogEntryRow: View {

    let entry: AuditLogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row
            HStack {
                // Category icon
                self.categoryIcon
                    .frame(width: 20)

                // Timestamp
                Text(self.formattedTime)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)

                // Summary
                Text(entry.summary)
                    .lineLimit(isExpanded ? nil : 1)

                Spacer()

                // Status indicator
                self.statusBadge

                // Expand button
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let tool = entry.toolName {
                        LabeledContent("Tool", value: tool)
                    }

                    if let parameters = entry.parameters, !parameters.isEmpty {
                        LabeledContent("Parameters") {
                            Text(self.formatJSON(parameters))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let result = entry.result {
                        LabeledContent("Result", value: result)
                    }

                    if let error = entry.errorMessage {
                        LabeledContent("Error") {
                            Text(error)
                                .foregroundColor(.red)
                        }
                    }

                    if let sessionID = entry.sessionID {
                        LabeledContent("Session", value: String(sessionID.uuidString.prefix(8)) + "...")
                    }
                }
                .font(.caption)
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var categoryIcon: some View {
        switch entry.category {
        case .toolExecution:
            Image(systemName: "hammer.fill")
                .foregroundColor(.blue)
        case .skillList, .skillLoad, .skillRead:
            Image(systemName: "sparkles")
                .foregroundColor(.mint)
        case .confirmation:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .stateChange:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if entry.success {
            Text("OK")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.2))
                .foregroundColor(.green)
                .cornerRadius(4)
        } else if entry.category == .error {
            Text("ERROR")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.2))
                .foregroundColor(.red)
                .cornerRadius(4)
        }
    }

    private var formattedTime: String {
        Self.formattedTime(for: entry.timestamp)
    }

    static func formattedTime(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatJSON(_ dict: [String: Any]) -> String {
        Self.formatJSON(dict)
    }

    static func formatJSON(_ dict: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: dict)
        }
        return string
    }
}
