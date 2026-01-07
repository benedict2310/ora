# X.05 — System Tools & Navigation

**Epic:** Tools  
**Status:** Not Started  
**Priority:** P1 (Important)  
**Estimated Effort:** 1.5–2.5 days  
**Dependencies:** X.01 (Tool Protocol)  
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Enable Ora to **navigate the system**, **handoff tasks to native apps**, and **trigger automations** safely. This should make the assistant feel like a true macOS companion, not just a launcher.

Example user intents:

- "Open Spotify and start my focus playlist" (via Shortcut)
- "Open my Downloads folder and show the file I just saved"
- "Open Wi‑Fi settings"
- "Run my Start Work shortcut"
- "Find invoice.pdf and reveal it in Finder"

---

## 2. Tool Set

### A) Launch & Open

| Tool | Kind | Description |
|------|------|-------------|
| `system.open_app` | read | Open an application by **bundle id or app name** |
| `system.open_url` | read | Open a URL in the default browser (auto-add scheme) |

#### `system.open_app` Parameters

- `bundle_id` (string, optional) — e.g. `com.apple.Safari`
- `app_name` (string, optional) — e.g. `Safari`, `Spotify`

At least one must be provided.

#### Result Payload

```json
{
  "opened": true,
  "bundle_id": "com.apple.Safari",
  "path": "/System/Applications/Safari.app",
  "already_running": false
}
```

---

### B) Finder Navigation

| Tool | Kind | Description |
|------|------|-------------|
| `system.open_path` | read | Open file or folder with default handler |
| `system.reveal_in_finder` | read | Reveal a file in Finder (select it) |
| `system.open_folder_special` | read | Open well-known folders |

#### `system.open_folder_special` Parameters

- `folder` (string, enum)
  - `downloads`
  - `desktop`
  - `documents`
  - `applications`
  - `home`

#### Result Payload

```json
{
  "opened": true,
  "path": "/Users/bene/Downloads"
}
```

---

### C) System Settings Deep Links

| Tool | Kind | Description |
|------|------|-------------|
| `system.open_settings` | read | Open System Settings, optionally a specific pane |

#### Parameters

- `pane` (string, optional)
  - examples: `wifi`, `bluetooth`, `privacy`, `notifications`, `sound`, `display`

If no pane is provided, open System Settings root.

#### Result Payload

```json
{
  "opened": true,
  "pane": "wifi"
}
```

---

### D) Search (Spotlight-style)

| Tool | Kind | Description |
|------|------|-------------|
| `system.search_files` | read | Search indexed files and return top matches |
| `system.search_apps` | read | Search installed applications |

#### `system.search_files` Parameters

- `query` (string, required)
- `limit` (number, optional, default 5)

#### Result Payload

```json
{
  "results": [
    { "name": "invoice.pdf", "path": "/Users/bene/Documents/invoice.pdf" }
  ]
}
```

---

### E) Shortcuts Bridge (High Leverage)

| Tool | Kind | Description |
|------|------|-------------|
| `system.run_shortcut` | mutate | Run a user Shortcut by name |
| `system.list_shortcuts` | read | List available Shortcuts (best-effort) |

#### `system.run_shortcut` Parameters

- `name` (string, required)
- `input` (string, optional)

#### Result Payload

```json
{
  "ran": true,
  "name": "Start Work"
}
```

#### Safety

- Marked as `mutate` (requires confirmation)
- Allowlist trusted shortcut names
- Require confirmation for non-allowlisted shortcuts

Rationale: Shortcuts can perform arbitrary actions; this prevents silent execution of destructive automations.

---

## 3. Implementation Strategy

### 3.1 App Resolution

Resolution order:

1. If `bundle_id` provided → resolve via `NSWorkspace.urlForApplication(withBundleIdentifier:)`
2. Else search cached app index:
   - `/Applications`
   - `/System/Applications`
   - `/System/Applications/Utilities`
   - `~/Applications`
3. Fallback: fuzzy name match and return suggestions

Cache results at startup to avoid repeated filesystem scans.

---

### 3.2 Finder Operations

Use `NSWorkspace` APIs:

- `open(_:)` for folders and files
- `activateFileViewerSelecting(_:)` for reveal-in-Finder behavior

Ensure path validation and clear error messages.

---

### 3.3 System Settings Deep Links

Open via URL schemes (examples):

- `x-apple.systempreferences:com.apple.WiFi-Settings`
- `x-apple.systempreferences:com.apple.Bluetooth`

Maintain a small mapping table for supported panes.

Fallback: open System Settings root if pane not recognized.

---

### 3.4 File Search

Preferred:

- `NSMetadataQuery` for Spotlight-indexed search

Fallback:

- FileManager crawl limited to common directories

Return ranked results; do not auto-open without explicit follow-up intent.

---

### 3.5 Shortcuts Execution

Execution options:

- `shortcuts run "Shortcut Name"` via `Process`
- Or App Intents (future upgrade)

Implementation steps:

1. Validate shortcut exists
2. Check allowlist / require confirmation
3. Execute
4. Return success/failure

---

## 4. Implementation Files

### 4.0 System Tool Errors

**File:** `Ora/Tools/System/SystemToolError.swift`

```swift
//
//  SystemToolError.swift
//  Ora
//
//  Errors for system tools
//

import Foundation

enum SystemToolError: LocalizedError {
    case notFound(String)
    case failed(String)
    case invalidArgument(String)
    
    var errorDescription: String? {
        switch self {
        case .notFound(let item):
            return "\(item) not found"
        case .failed(let reason):
            return "Operation failed: \(reason)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        }
    }
}
```

### 4.1 Open App Tool

**File:** `Ora/Tools/System/SystemOpenAppTool.swift`

```swift
//
//  SystemOpenAppTool.swift
//  Ora
//
//  Open applications by bundle ID or name
//

import Foundation
import AppKit

struct SystemOpenAppTool: Tool {
    let name = "system.open_app"
    let kind: ToolKind = .read  // No confirmation needed
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open an application by bundle ID or name",
            parameters: [
                "bundle_id": ParameterSchema(type: "string", description: "Bundle identifier (e.g., 'com.apple.Safari')", format: nil),
                "app_name": ParameterSchema(type: "string", description: "Application name (e.g., 'Safari', 'Spotify')", format: nil)
            ],
            requiredParameters: [],  // At least one must be provided
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        let bundleId = args["bundle_id"]?.stringValue
        let appName = args["app_name"]?.stringValue
        
        guard (bundleId != nil && !bundleId!.isEmpty) || (appName != nil && !appName!.isEmpty) else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: bundle_id or app_name")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let workspace = NSWorkspace.shared
        
        // Try bundle ID first
        if let bundleId = args["bundle_id"]?.stringValue, !bundleId.isEmpty {
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
                let alreadyRunning = workspace.runningApplications.contains { $0.bundleIdentifier == bundleId }
                let config = NSWorkspace.OpenConfiguration()
                try await workspace.openApplication(at: appURL, configuration: config)
                return .success(
                    .object([
                        "opened": .bool(true),
                        "bundle_id": .string(bundleId),
                        "path": .string(appURL.path),
                        "already_running": .bool(alreadyRunning)
                    ]),
                    summary: "Opened \(appURL.deletingPathExtension().lastPathComponent)."
                )
            }
        }
        
        // Try app name
        if let appName = args["app_name"]?.stringValue, !appName.isEmpty {
            if let appURL = findAppByName(appName) {
                let bundleId = Bundle(url: appURL)?.bundleIdentifier
                let alreadyRunning = bundleId.map { id in
                    workspace.runningApplications.contains { $0.bundleIdentifier == id }
                } ?? false
                
                let config = NSWorkspace.OpenConfiguration()
                try await workspace.openApplication(at: appURL, configuration: config)
                return .success(
                    .object([
                        "opened": .bool(true),
                        "bundle_id": .string(bundleId ?? ""),
                        "path": .string(appURL.path),
                        "already_running": .bool(alreadyRunning)
                    ]),
                    summary: "Opened \(appName)."
                )
            }
            
            throw SystemToolError.notFound("Application '\(appName)'")
        }
        
        throw SystemToolError.invalidArgument("Bundle ID or app name required")
    }
    
    private func findAppByName(_ name: String) -> URL? {
        let workspace = NSWorkspace.shared
        
        // Check running apps first
        if let app = workspace.runningApplications.first(where: { 
            $0.localizedName?.lowercased() == name.lowercased() 
        }) {
            return app.bundleURL
        }
        
        // Search common locations
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        
        for basePath in searchPaths {
            let directPath = URL(fileURLWithPath: "\(basePath)/\(name).app")
            if FileManager.default.fileExists(atPath: directPath.path) {
                return directPath
            }
            
            // Fuzzy search in directory
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: nil
            ) {
                if let match = contents.first(where: {
                    $0.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased()
                }) {
                    return match
                }
            }
        }
        
        return nil
    }
}
```

### 4.2 Open URL Tool

**File:** `Ora/Tools/System/SystemOpenURLTool.swift`

```swift
//
//  SystemOpenURLTool.swift
//  Ora
//
//  Open URLs in default browser
//

import Foundation
import AppKit

struct SystemOpenURLTool: Tool {
    let name = "system.open_url"
    let kind: ToolKind = .read  // No confirmation needed
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a URL in the default browser",
            parameters: [
                "url": ParameterSchema(type: "string", description: "URL to open", format: "uri")
            ],
            requiredParameters: ["url"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let urlString = args["url"]?.stringValue, !urlString.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: url")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let urlString = args["url"]?.stringValue else {
            throw SystemToolError.invalidArgument("URL required")
        }
        
        // Normalize URL - add https:// if no scheme
        var normalizedURLString = urlString
        if !urlString.contains("://") {
            normalizedURLString = "https://\(urlString)"
        }
        
        guard let url = URL(string: normalizedURLString) else {
            throw SystemToolError.invalidArgument("Invalid URL: \(urlString)")
        }
        
        let success = NSWorkspace.shared.open(url)
        
        if success {
            return .success(
                .object(["opened": .bool(true), "url": .string(url.absoluteString)]),
                summary: "Opened \(url.host ?? urlString) in your browser."
            )
        } else {
            throw SystemToolError.failed("Failed to open URL")
        }
    }
}
```

### 4.3 Open Path Tool

**File:** `Ora/Tools/System/SystemOpenPathTool.swift`

```swift
//
//  SystemOpenPathTool.swift
//  Ora
//
//  Open files or folders with their default handler
//

import Foundation
import AppKit

struct SystemOpenPathTool: Tool {
    let name = "system.open_path"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a file or folder with its default handler",
            parameters: [
                "path": ParameterSchema(type: "string", description: "Path to file or folder", format: nil)
            ],
            requiredParameters: ["path"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let path = args["path"]?.stringValue, !path.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: path")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let path = args["path"]?.stringValue else {
            throw SystemToolError.invalidArgument("Path required")
        }
        
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SystemToolError.notFound("Path '\(path)'")
        }
        
        let success = NSWorkspace.shared.open(url)
        
        if success {
            let name = url.lastPathComponent
            return .success(
                .object(["opened": .bool(true), "path": .string(expandedPath)]),
                summary: "Opened \(name)."
            )
        } else {
            throw SystemToolError.failed("Failed to open path")
        }
    }
}
```

### 4.4 Reveal in Finder Tool

**File:** `Ora/Tools/System/SystemRevealInFinderTool.swift`

```swift
//
//  SystemRevealInFinderTool.swift
//  Ora
//
//  Reveal a file in Finder (select it)
//

import Foundation
import AppKit

struct SystemRevealInFinderTool: Tool {
    let name = "system.reveal_in_finder"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Reveal a file in Finder and select it",
            parameters: [
                "path": ParameterSchema(type: "string", description: "Path to file to reveal", format: nil)
            ],
            requiredParameters: ["path"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let path = args["path"]?.stringValue, !path.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: path")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let path = args["path"]?.stringValue else {
            throw SystemToolError.invalidArgument("Path required")
        }
        
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SystemToolError.notFound("File '\(path)'")
        }
        
        NSWorkspace.shared.activateFileViewerSelecting([url])
        
        let name = url.lastPathComponent
        return .success(
            .object(["revealed": .bool(true), "path": .string(expandedPath)]),
            summary: "Revealed \(name) in Finder."
        )
    }
}
```

### 4.5 Open Special Folder Tool

**File:** `Ora/Tools/System/SystemOpenFolderSpecialTool.swift`

```swift
//
//  SystemOpenFolderSpecialTool.swift
//  Ora
//
//  Open well-known system folders
//

import Foundation
import AppKit

struct SystemOpenFolderSpecialTool: Tool {
    let name = "system.open_folder_special"
    let kind: ToolKind = .read
    
    private static let folderMap: [String: FileManager.SearchPathDirectory] = [
        "downloads": .downloadsDirectory,
        "desktop": .desktopDirectory,
        "documents": .documentDirectory,
        "applications": .applicationDirectory,
        "home": .userDirectory
    ]
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open a well-known folder (downloads, desktop, documents, applications, home)",
            parameters: [
                "folder": ParameterSchema(type: "string", description: "Folder name: downloads, desktop, documents, applications, home", format: nil)
            ],
            requiredParameters: ["folder"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let folder = args["folder"]?.stringValue, !folder.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: folder")
        }
        guard Self.folderMap.keys.contains(folder.lowercased()) else {
            throw ToolHostError.validationFailed(name, "folder must be one of: downloads, desktop, documents, applications, home")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let folder = args["folder"]?.stringValue?.lowercased() else {
            throw SystemToolError.invalidArgument("Folder name required")
        }
        
        let path: String
        if folder == "home" {
            path = NSHomeDirectory()
        } else if let searchPath = Self.folderMap[folder],
                  let url = FileManager.default.urls(for: searchPath, in: .userDomainMask).first {
            path = url.path
        } else {
            throw SystemToolError.notFound("Unknown folder: \(folder)")
        }
        
        let url = URL(fileURLWithPath: path)
        let success = NSWorkspace.shared.open(url)
        
        if success {
            return .success(
                .object(["opened": .bool(true), "path": .string(path)]),
                summary: "Opened \(folder.capitalized) folder."
            )
        } else {
            throw SystemToolError.failed("Failed to open \(folder) folder")
        }
    }
}
```

### 4.6 Open Settings Tool

**File:** `Ora/Tools/System/SystemOpenSettingsTool.swift`

```swift
//
//  SystemOpenSettingsTool.swift
//  Ora
//
//  Open System Settings, optionally a specific pane
//

import Foundation
import AppKit

struct SystemOpenSettingsTool: Tool {
    let name = "system.open_settings"
    let kind: ToolKind = .read
    
    private static let paneMap: [String: String] = [
        "wifi": "com.apple.wifi-settings-extension",
        "bluetooth": "com.apple.BluetoothSettings",
        "privacy": "com.apple.preference.security",
        "notifications": "com.apple.Notifications-Settings.extension",
        "sound": "com.apple.preference.sound",
        "display": "com.apple.Displays-Settings.extension",
        "keyboard": "com.apple.Keyboard-Settings.extension",
        "trackpad": "com.apple.Trackpad-Settings.extension",
        "mouse": "com.apple.Mouse-Settings.extension",
        "network": "com.apple.Network-Settings.extension",
        "battery": "com.apple.Battery-Settings.extension",
        "general": "com.apple.systempreferences.GeneralSettings"
    ]
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open System Settings, optionally a specific pane (wifi, bluetooth, privacy, notifications, sound, display, keyboard, trackpad, mouse, network, battery, general)",
            parameters: [
                "pane": ParameterSchema(type: "string", description: "Settings pane to open (optional)", format: nil)
            ],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        // pane is optional, validation happens in execute
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let pane = args["pane"]?.stringValue?.lowercased()
        
        if let pane = pane, let paneId = Self.paneMap[pane] {
            // Open specific pane
            let urlString = "x-apple.systempreferences:\(paneId)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return .success(
                    .object(["opened": .bool(true), "pane": .string(pane)]),
                    summary: "\(pane.capitalized) settings are open."
                )
            }
        }
        
        // Open System Settings root
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        let config = NSWorkspace.OpenConfiguration()
        try await NSWorkspace.shared.openApplication(at: settingsURL, configuration: config)
        
        return .success(
            .object(["opened": .bool(true), "pane": .null]),
            summary: "System Settings is open."
        )
    }
}
```

### 4.7 Search Files Tool

**File:** `Ora/Tools/System/SystemSearchFilesTool.swift`

```swift
//
//  SystemSearchFilesTool.swift
//  Ora
//
//  Search indexed files using Spotlight
//

import Foundation

struct SystemSearchFilesTool: Tool {
    let name = "system.search_files"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search for files using Spotlight index",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Search query", format: nil),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 5)", format: nil)
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let query = args["query"]?.stringValue else {
            throw SystemToolError.invalidArgument("Query required")
        }
        
        let limit = Int(args["limit"]?.numberValue ?? 5)
        
        let results = await searchWithSpotlight(query: query, limit: limit)
        
        let resultArray = results.map { result in
            JSONValue.object([
                "name": .string(result.name),
                "path": .string(result.path)
            ])
        }
        
        let summary = results.isEmpty 
            ? "No files found for '\(query)'."
            : "Found \(results.count) file\(results.count == 1 ? "" : "s")."
        
        return .success(
            .object(["results": .array(resultArray)]),
            summary: summary
        )
    }
    
    @MainActor
    private func searchWithSpotlight(query: String, limit: Int) async -> [(name: String, path: String)] {
        await withCheckedContinuation { continuation in
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", query)
            metadataQuery.searchScopes = [
                NSMetadataQueryUserHomeScope,
                NSMetadataQueryLocalComputerScope
            ]
            
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                metadataQuery.stop()
                
                var results: [(name: String, path: String)] = []
                let count = min(metadataQuery.resultCount, limit)
                
                for i in 0..<count {
                    if let item = metadataQuery.result(at: i) as? NSMetadataItem,
                       let path = item.value(forAttribute: kMDItemPath as String) as? String {
                        let name = (path as NSString).lastPathComponent
                        results.append((name: name, path: path))
                    }
                }
                
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                
                continuation.resume(returning: results)
            }
            
            metadataQuery.start()
            
            // Timeout after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if metadataQuery.isGathering {
                    metadataQuery.stop()
                    if let observer = observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    continuation.resume(returning: [])
                }
            }
        }
    }
}
```

### 4.8 Search Apps Tool

**File:** `Ora/Tools/System/SystemSearchAppsTool.swift`

```swift
//
//  SystemSearchAppsTool.swift
//  Ora
//
//  Search installed applications
//

import Foundation

struct SystemSearchAppsTool: Tool {
    let name = "system.search_apps"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search installed applications by name",
            parameters: [
                "query": ParameterSchema(type: "string", description: "App name to search for", format: nil),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 5)", format: nil)
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let query = args["query"]?.stringValue else {
            throw SystemToolError.invalidArgument("Query required")
        }
        
        let limit = Int(args["limit"]?.numberValue ?? 5)
        let results = searchApps(query: query, limit: limit)
        
        let resultArray = results.map { app in
            JSONValue.object([
                "name": .string(app.name),
                "bundle_id": .string(app.bundleId ?? ""),
                "path": .string(app.path)
            ])
        }
        
        let summary = results.isEmpty 
            ? "No apps found matching '\(query)'."
            : "Found \(results.count) app\(results.count == 1 ? "" : "s")."
        
        return .success(
            .object(["results": .array(resultArray)]),
            summary: summary
        )
    }
    
    private func searchApps(query: String, limit: Int) -> [(name: String, bundleId: String?, path: String)] {
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        
        var results: [(name: String, bundleId: String?, path: String)] = []
        let lowercaseQuery = query.lowercased()
        
        for basePath in searchPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
                continue
            }
            
            for item in contents where item.hasSuffix(".app") {
                let appName = (item as NSString).deletingPathExtension
                if appName.lowercased().contains(lowercaseQuery) {
                    let fullPath = "\(basePath)/\(item)"
                    let bundleId = Bundle(path: fullPath)?.bundleIdentifier
                    results.append((name: appName, bundleId: bundleId, path: fullPath))
                    
                    if results.count >= limit {
                        return results
                    }
                }
            }
        }
        
        return results
    }
}
```

### 4.9 Run Shortcut Tool

**File:** `Ora/Tools/System/SystemRunShortcutTool.swift`

```swift
//
//  SystemRunShortcutTool.swift
//  Ora
//
//  Run user Shortcuts by name
//

import Foundation

struct SystemRunShortcutTool: Tool {
    let name = "system.run_shortcut"
    let kind: ToolKind = .mutate  // Requires confirmation
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Run a Shortcut by name. Requires confirmation.",
            parameters: [
                "name": ParameterSchema(type: "string", description: "Name of the Shortcut to run", format: nil),
                "input": ParameterSchema(type: "string", description: "Optional input to pass to the Shortcut", format: nil)
            ],
            requiredParameters: ["name"],
            requiresConfirmation: true
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let name = args["name"]?.stringValue, !name.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: name")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let shortcutName = args["name"]?.stringValue else {
            throw SystemToolError.invalidArgument("Shortcut name required")
        }
        
        let input = args["input"]?.stringValue
        
        // Build command
        var arguments = ["run", shortcutName]
        if let input = input {
            arguments.append(contentsOf: ["-i", input])
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                return .success(
                    .object(["ran": .bool(true), "name": .string(shortcutName)]),
                    summary: "Ran \(shortcutName) shortcut."
                )
            } else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw SystemToolError.failed("Shortcut failed: \(errorMessage)")
            }
        } catch let error as SystemToolError {
            throw error
        } catch {
            throw SystemToolError.failed("Failed to run shortcut: \(error.localizedDescription)")
        }
    }
}
```

### 4.10 List Shortcuts Tool

**File:** `Ora/Tools/System/SystemListShortcutsTool.swift`

```swift
//
//  SystemListShortcutsTool.swift
//  Ora
//
//  List available Shortcuts
//

import Foundation

struct SystemListShortcutsTool: Tool {
    let name = "system.list_shortcuts"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List available Shortcuts",
            parameters: [:],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        // No parameters required
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            let shortcuts = output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            let resultArray = shortcuts.map { JSONValue.string($0) }
            
            return .success(
                .object(["shortcuts": .array(resultArray), "count": .number(Double(shortcuts.count))]),
                summary: "Found \(shortcuts.count) shortcut\(shortcuts.count == 1 ? "" : "s")."
            )
        } catch {
            throw SystemToolError.failed("Failed to list shortcuts: \(error.localizedDescription)")
        }
    }
}
```

---

## 5. ToolRegistry Integration

Add to `ToolRegistry.registerDefaultTools()`:

```swift
// System tools
register(SystemOpenAppTool())
register(SystemOpenURLTool())
register(SystemOpenPathTool())
register(SystemRevealInFinderTool())
register(SystemOpenFolderSpecialTool())
register(SystemOpenSettingsTool())
register(SystemSearchFilesTool())
register(SystemSearchAppsTool())
register(SystemRunShortcutTool())
register(SystemListShortcutsTool())
```

---

## 6. Acceptance Criteria

### Core

- [ ] AC-1: `system.open_app` supports bundle id and name
- [ ] AC-2: `system.open_url` normalizes missing scheme (adds https://)
- [ ] AC-3: `system.open_path` opens files and folders
- [ ] AC-4: `system.reveal_in_finder` selects file in Finder
- [ ] AC-5: `system.open_settings` opens at least 3 panes (wifi, bluetooth, privacy)
- [ ] AC-6: `system.open_folder_special` opens all 5 folder types
- [ ] AC-7: All tools return structured JSON + short TTS summary

### Search

- [ ] AC-8: `system.search_files` returns ranked matches via Spotlight
- [ ] AC-9: `system.search_apps` returns name, bundle id, path

### Shortcuts

- [ ] AC-10: `system.run_shortcut` runs shortcuts by name
- [ ] AC-11: `system.list_shortcuts` lists available shortcuts
- [ ] AC-12: Confirmation required for `system.run_shortcut` (mutate tool)

---

## 7. Implementation Checklist

- [ ] Create `Ora/Tools/System/` directory
- [ ] Create `SystemToolError.swift`
- [ ] Create `SystemOpenAppTool.swift`
- [ ] Create `SystemOpenURLTool.swift`
- [ ] Create `SystemOpenPathTool.swift`
- [ ] Create `SystemRevealInFinderTool.swift`
- [ ] Create `SystemOpenFolderSpecialTool.swift`
- [ ] Create `SystemOpenSettingsTool.swift`
- [ ] Create `SystemSearchFilesTool.swift`
- [ ] Create `SystemSearchAppsTool.swift`
- [ ] Create `SystemRunShortcutTool.swift`
- [ ] Create `SystemListShortcutsTool.swift`
- [ ] Register all tools in `ToolRegistry.registerDefaultTools()`
- [ ] Update system prompt with new capabilities (already done)
- [ ] Write unit tests for each tool
- [ ] Manual E2E testing

---

## 8. Out of Scope (Future Stories)

These require extra permissions and more complex UX:

- Window and UI control (Accessibility permission)
- Clipboard read access
- Screenshot and screen understanding (ScreenCaptureKit)
- Global text injection

These should be separate epics due to privacy and trust implications.

---

## 9. Tool Result Guidelines

All system tools must:

1. Return machine-readable JSON
2. Include success flags and relevant metadata
3. Provide a concise human summary for TTS

Examples:

- "Opened Downloads folder"
- "Wi‑Fi settings are open"
- "I couldn't find an app called 'X' — did you mean Y?"

This keeps the agent loop deterministic while maintaining natural UX.
