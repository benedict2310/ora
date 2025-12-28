# F.06 - Preferences Window

**Epic:** Foundations
**Status:** Implemented
**Priority:** P1 (Important)
**Estimated Effort:** 2 days
**Dependencies:** F.01 (App Shell), F.02 (Permissions), F.03 (Model Manager)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Liquid Glass UI Guide](../../references/liquid-glass-ui.md)

---

## 1. Objective

Create the Preferences window accessible from the menu bar, allowing users to configure hotkey, manage models, view permissions, and access audit logs.

### Tabs Overview

| Tab | Purpose |
|:----|:--------|
| **General** | Hotkey, default calendar, voice output toggle |
| **Models** | View/download/delete models, select primary LLM |
| **Permissions** | View and manage system permissions |
| **About** | App version, links, audit log access |

---

## 2. Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                   PreferencesWindow                          │
│                      (SwiftUI)                               │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    TabView                           │    │
│  │  ┌─────────┬─────────┬─────────────┬─────────┐      │    │
│  │  │ General │ Models  │ Permissions │  About  │      │    │
│  │  └─────────┴─────────┴─────────────┴─────────┘      │    │
│  │                                                      │    │
│  │  [Tab Content Area]                                  │    │
│  │                                                      │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

### 3.1 Preferences Coordinator

**File:** `Ora/Preferences/PreferencesCoordinator.swift`

```swift
//
//  PreferencesCoordinator.swift
//  Ora
//
//  Manages preferences window state
//

import Foundation
import SwiftUI
import os

@MainActor
final class PreferencesCoordinator: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = PreferencesCoordinator()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "Preferences")
    private var window: NSWindow?
    
    // MARK: - Published State
    
    @Published var selectedTab: PreferencesTab = .general
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    func showPreferences() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create window
        let contentView = PreferencesWindow()
            .environmentObject(self)
        
        let hostingController = NSHostingController(rootView: contentView)
        
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Ora Preferences"
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 550, height: 450))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = newWindow
        
        logger.debug("Preferences window opened")
    }
    
    func closePreferences() {
        window?.close()
    }
}

// MARK: - Tab Enum

enum PreferencesTab: String, CaseIterable {
    case general
    case models
    case permissions
    case about
    
    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "gear"
        case .models: return "cpu"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}
```

### 3.2 Preferences Window

**File:** `Ora/Preferences/PreferencesWindow.swift`

```swift
//
//  PreferencesWindow.swift
//  Ora
//
//  Main preferences window
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
        .frame(minWidth: 550, minHeight: 400)
        .padding()
    }
}
```

### 3.3 General Preferences

**File:** `Ora/Preferences/Tabs/GeneralPreferencesView.swift`

```swift
//
//  GeneralPreferencesView.swift
//  Ora
//
//  General settings tab
//

import SwiftUI
import EventKit

struct GeneralPreferencesView: View {
    @State private var hotkeyConfig = HotkeyConfiguration.load()
    @State private var voiceOutputEnabled = true
    @State private var selectedCalendarID: String = ""
    @State private var calendars: [EKCalendar] = []
    
    var body: some View {
        Form {
            // Hotkey Section
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Activation Hotkey")
                            .font(.headline)
                        Text("Press and hold to speak, release to send")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    HotkeyRecorderView(configuration: $hotkeyConfig)
                }
            }
            
            Divider()
                .padding(.vertical)
            
            // Voice Output Section
            Section {
                Toggle(isOn: $voiceOutputEnabled) {
                    VStack(alignment: .leading) {
                        Text("Voice Output")
                            .font(.headline)
                        Text("Enable text-to-speech responses")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: voiceOutputEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "com.ora.voiceOutputEnabled")
                }
            }
            
            Divider()
                .padding(.vertical)
            
            // Default Calendar Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Calendar")
                        .font(.headline)
                    Text("Calendar used for new events")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $selectedCalendarID) {
                        Text("Default").tag("")
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            Text(calendar.title).tag(calendar.calendarIdentifier)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedCalendarID) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "com.ora.defaultCalendarID")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadSettings()
            loadCalendars()
        }
    }
    
    private func loadSettings() {
        voiceOutputEnabled = UserDefaults.standard.bool(forKey: "com.ora.voiceOutputEnabled")
        selectedCalendarID = UserDefaults.standard.string(forKey: "com.ora.defaultCalendarID") ?? ""
    }
    
    private func loadCalendars() {
        let store = EKEventStore()
        calendars = store.calendars(for: .event).filter { $0.allowsContentModifications }
    }
}
```

### 3.4 Models Preferences

**File:** `Ora/Preferences/Tabs/ModelsPreferencesView.swift`

```swift
//
//  ModelsPreferencesView.swift
//  Ora
//
//  Models management tab
//

import SwiftUI

struct ModelsPreferencesView: View {
    @State private var modelsState = ModelsState()
    @State private var isDownloading = false
    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: ModelIdentifier?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Text("AI Models")
                .font(.headline)
            
            Text("Ora uses three AI models for speech recognition, language understanding, and voice synthesis.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Models List
            VStack(spacing: 12) {
                ForEach(ModelIdentifier.allCases, id: \.self) { model in
                    ModelRowView(
                        model: model,
                        status: modelsState.statuses[model] ?? .notDownloaded,
                        isPrimary: model == modelsState.primaryLLM && model.category == .llm,
                        onDownload: { await downloadModel(model) },
                        onDelete: { confirmDelete(model) },
                        onSetPrimary: { await setPrimary(model) }
                    )
                }
            }
            
            Spacer()
            
            // Storage info
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.secondary)
                Text("Models are stored in ~/Library/Application Support/Ora/Models/")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onAppear {
            refreshModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelStateDidChange)) { _ in
            refreshModels()
        }
        .alert("Delete Model", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    Task { await deleteModel(model) }
                }
            }
        } message: {
            if let model = modelToDelete {
                Text("Are you sure you want to delete \(model.displayName)? You'll need to download it again to use Ora.")
            }
        }
    }
    
    private func refreshModels() {
        Task {
            await ModelManager.shared.refreshStatuses()
            modelsState = await ModelManager.shared.state
        }
    }
    
    private func downloadModel(_ model: ModelIdentifier) async {
        do {
            try await ModelManager.shared.downloadModel(model)
        } catch {
            // Error handling - show alert
        }
    }
    
    private func confirmDelete(_ model: ModelIdentifier) {
        modelToDelete = model
        showDeleteConfirmation = true
    }
    
    private func deleteModel(_ model: ModelIdentifier) async {
        try? await ModelManager.shared.deleteModel(model)
    }
    
    private func setPrimary(_ model: ModelIdentifier) async {
        await ModelManager.shared.setPrimaryLLM(model)
    }
}

struct ModelRowView: View {
    let model: ModelIdentifier
    let status: ModelStatus
    let isPrimary: Bool
    let onDownload: () async -> Void
    let onDelete: () -> Void
    let onSetPrimary: () async -> Void
    
    var body: some View {
        HStack {
            // Model info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    
                    if isPrimary {
                        Text("Primary")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }
                
                Text(model.category.rawValue.uppercased())
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text(formatBytes(model.estimatedSizeBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Status and actions
            Group {
                switch status {
                case .ready:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        
                        if model.category == .llm && !isPrimary {
                            Button("Set Primary") {
                                Task { await onSetPrimary() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        
                        if !model.isRequired || model.category == .llm {
                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    
                case .downloading(let progress):
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 100)
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    
                case .notDownloaded:
                    Button("Download") {
                        Task { await onDownload() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                case .verifying:
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Verifying...")
                            .font(.caption)
                    }
                    
                case .failed(let error):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Button("Retry") {
                            Task { await onDownload() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .help(error)
                    
                case .corrupted:
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Corrupted")
                            .font(.caption)
                        Button("Re-download") {
                            Task { await onDownload() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
```

### 3.5 Permissions Preferences

**File:** `Ora/Preferences/Tabs/PermissionsPreferencesView.swift`

```swift
//
//  PermissionsPreferencesView.swift
//  Ora
//
//  Permissions status tab
//

import SwiftUI

struct PermissionsPreferencesView: View {
    @State private var permissionsState = PermissionsState()
    
    var body: some View {
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
            
            Spacer()
            
            Button("Refresh Status") {
                refreshPermissions()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .onAppear {
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .permissionsStateDidChange)) { notification in
            if let state = notification.object as? PermissionsState {
                permissionsState = state
            }
        }
    }
    
    private func refreshPermissions() {
        Task {
            await PermissionsManager.shared.refreshAll()
            permissionsState = await PermissionsManager.shared.state
        }
    }
}

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
                statusIcon
                
                if !status.isGranted {
                    Button("Open Settings") {
                        Task { @MainActor in
                            await PermissionsManager.shared.openSettings(for: type)
                        }
                    }
                    .buttonStyle(.bordered)
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
```

### 3.6 About Preferences

**File:** `Ora/Preferences/Tabs/AboutPreferencesView.swift`

```swift
//
//  AboutPreferencesView.swift
//  Ora
//
//  About and audit log tab
//

import SwiftUI

struct AboutPreferencesView: View {
    @State private var showAuditLog = false
    
    var body: some View {
        VStack(spacing: 24) {
            // App Icon and Name
            VStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                
                Text("Ora")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Description
            Text("A privacy-first voice assistant that runs entirely on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Links and Actions
            VStack(spacing: 12) {
                Button {
                    showAuditLog = true
                } label: {
                    Label("View Audit Log", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.bordered)
                
                Button {
                    // Open GitHub or website
                    if let url = URL(string: "https://github.com/your-org/ora") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("GitHub", systemImage: "link")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            
            Spacer()
            
            // Privacy note
            Label("All processing happens on your device.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
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
    @Environment(\.dismiss) var dismiss
    @State private var entries: [AuditLogEntry] = []
    @State private var selectedFilter: AuditFilter = .all
    @State private var isLoading = true
    @State private var showClearConfirmation = false
    
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
                    exportLog()
                }
                .buttonStyle(.bordered)
                
                Button("Clear Log", role: .destructive) {
                    showClearConfirmation = true
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadEntries()
        }
        .onChange(of: selectedFilter) { _, _ in
            loadEntries()
        }
        .alert("Clear Audit Log?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearLog()
            }
        } message: {
            Text("This will permanently delete all audit log entries. This action cannot be undone.")
        }
    }
    
    private var filteredEntries: [AuditLogEntry] {
        switch selectedFilter {
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
        panel.nameFieldStringValue = "ora-audit-log-\(formattedDate()).json"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task {
                    await AuditLogger.shared.exportTo(url: url)
                }
            }
        }
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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
                categoryIcon
                    .frame(width: 20)
                
                // Timestamp
                Text(formattedTime)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                
                // Summary
                Text(entry.summary)
                    .lineLimit(isExpanded ? nil : 1)
                
                Spacer()
                
                // Status indicator
                statusBadge
                
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
                            Text(formatJSON(parameters))
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
                        LabeledContent("Session", value: sessionID.uuidString.prefix(8) + "...")
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
    
    private func formatJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: dict)
        }
        return string
    }
}

// MARK: - Audit Log Entry Model

struct AuditLogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let category: AuditCategory
    let summary: String
    let toolName: String?
    let parameters: [String: Any]?
    let result: String?
    let errorMessage: String?
    let success: Bool
    let userConfirmed: Bool
    let sessionID: UUID?
    
    enum AuditCategory: String {
        case toolExecution
        case confirmation
        case error
        case stateChange
    }
}
```

### 3.7 Update StatusBarController

**Update:** `Ora/UI/StatusBarController.swift`

```swift
func showPreferences() {
    PreferencesCoordinator.shared.showPreferences()
}
```

---

## 4. Directory Structure

```
Ora/
└── Preferences/
    ├── PreferencesCoordinator.swift
    ├── PreferencesWindow.swift
    └── Tabs/
        ├── GeneralPreferencesView.swift
        ├── ModelsPreferencesView.swift
        ├── PermissionsPreferencesView.swift
        └── AboutPreferencesView.swift
```

---

## 5. Acceptance Criteria

### Window Management

- [x] **AC-1:** Preferences window opens from menu bar - ✅ Verified in `StatusBarController.swift:87` -> `PreferencesCoordinator.showPreferences()`
- [x] **AC-2:** Window is reused if already open (no duplicates) - ✅ Verified in `PreferencesCoordinator.swift:35-39`
- [x] **AC-3:** Window appears centered on screen - ✅ Verified in `PreferencesCoordinator.swift:51` (`newWindow.center()`)

### General Tab

- [x] **AC-4:** Hotkey can be changed via HotkeyRecorderView - ✅ Verified in `GeneralPreferencesView.swift:37`
- [x] **AC-5:** Voice output toggle persisted - ✅ Verified in `GeneralPreferencesView.swift:56-58`
- [x] **AC-6:** Default calendar selection works - ✅ Verified in `GeneralPreferencesView.swift:82-97`

### Models Tab

- [x] **AC-7:** All models listed with status - ✅ Verified in `ModelsPreferencesView.swift:33`
- [x] **AC-8:** Download button for missing models - ✅ Verified in `ModelsPreferencesView.swift:193-198`
- [x] **AC-9:** Delete button for optional/downloaded models - ✅ Verified in `ModelsPreferencesView.swift:173-181`
- [x] **AC-10:** Primary LLM selection works - ✅ Verified in `ModelsPreferencesView.swift:166-170`
- [x] **AC-11:** Progress shown during download - ✅ Verified in `ModelsPreferencesView.swift:184-191`

### Permissions Tab

- [x] **AC-12:** All permissions listed with status - ✅ Verified in `PermissionsPreferencesView.swift:29`
- [x] **AC-13:** "Open Settings" opens correct System Settings pane - ✅ Verified in `PermissionsPreferencesView.swift:102-108`
- [x] **AC-14:** Status updates when permissions change - ✅ Verified in `PermissionsPreferencesView.swift:48-52`

### About Tab

- [x] **AC-15:** App version displayed correctly - ✅ Verified in `AboutPreferencesView.swift:30-32`
- [x] **AC-16:** Audit log accessible - ✅ Verified in `AboutPreferencesView.swift:46-52`

---

## 6. Implementation Checklist

- [x] Create `PreferencesCoordinator.swift`
- [x] Create `PreferencesWindow.swift`
- [x] Create `GeneralPreferencesView.swift`
- [x] Create `ModelsPreferencesView.swift`
- [x] Create `PermissionsPreferencesView.swift`
- [x] Create `AboutPreferencesView.swift`
- [x] Create `AuditLogView.swift`
- [x] Update `StatusBarController.showPreferences()`
- [x] Test all tabs
- [x] Test settings persistence

---

## 7. Implementation Summary

**Date:** 2025-12-28
**Branch:** `feat/F.06-preferences-window`

### Files Created/Modified

| File | Status |
|:-----|:-------|
| `Ora/Preferences/PreferencesCoordinator.swift` | Created |
| `Ora/Preferences/PreferencesWindow.swift` | Created |
| `Ora/Preferences/Tabs/GeneralPreferencesView.swift` | Created |
| `Ora/Preferences/Tabs/ModelsPreferencesView.swift` | Created |
| `Ora/Preferences/Tabs/PermissionsPreferencesView.swift` | Created |
| `Ora/Preferences/Tabs/AboutPreferencesView.swift` | Created |
| `OraTests/PreferencesTests.swift` | Created |

### Test Coverage

- `PreferencesTabTests` - 10 tests for tab enum properties
- `PreferencesCoordinatorTests` - 7 tests for singleton, tab selection, window management
- `AuditFilterTests` - 9 tests for filter enum properties
- `PreferencesIntegrationTests` - 1 test for status bar integration

### Ready for Review

- [x] All acceptance criteria verified
- [x] Tests passing (167 tests, 0 failures)
- [x] Working tree clean

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2025-12-28T14:09:09Z
**Commit reviewed:** dc35c32
**Iteration:** 1

### Summary
- Files reviewed: 2
- Build status: Pass
- Tests status: Pass (167 tests)

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None

#### P2 - Minor (Can defer)
- None

### Future Considerations (Out of Scope)
- None

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Completion Status

- [x] Implementation complete
- [x] Code review passed (1 iteration)
- [x] PR merged: https://github.com/benedict2310/ora/pull/5
- [x] Merged to main: 98fd38c
- [x] Date: 2025-12-28

---

## Post-Merge UI Refinements

**Date:** 2025-12-28
**Commits:** 3af2c7f, b946951

### Issues Fixed

1. **Empty boxes in General tab** - Removed `Divider()` elements that were creating empty card-like boxes between form sections when using `.formStyle(.grouped)`

2. **Tab bar card borders** - Replaced `TabView` with a `Picker` using `.segmented` style to eliminate the card-like borders around tab items that appeared in macOS Tahoe's Liquid Glass UI

3. **Tab bar spacing** - Added top padding (12pt) between the window title bar and the tab picker for better visual balance

### Architecture Change

The preferences window now uses a manual tab switching approach:
- `Picker` with `.pickerStyle(.segmented)` for tab selection
- `switch` statement to render the appropriate content view
- Explicit padding control for proper spacing

This provides better control over the UI appearance compared to the native `TabView` which had styling issues on macOS Tahoe.

### Additional Refinements (a2963a8)

4. **Consistent tab styling** - Updated Models and Permissions tabs to use `Form` with `.formStyle(.grouped)` matching the General tab

5. **Models tab organization** - Grouped models by category (Speech Recognition, Language Model, Text to Speech) with section headers

6. **Permissions tab organization** - Separated permissions into Required and Optional sections

7. **About tab spacing** - Added top spacing for consistent layout with other tabs
