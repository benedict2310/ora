# X.05 - System Tools

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 0.5 days
**Dependencies:** X.01 (Tool Protocol)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement system tools for opening applications and URLs.

---

## 2. Tools

| Tool | Kind | Description |
|:-----|:-----|:------------|
| `system.open_app` | read | Open an application by name |
| `system.open_url` | read | Open a URL in default browser |

---

## 3. Implementation

### 3.1 Open App Tool

**File:** `Ora/Tools/System/SystemOpenAppTool.swift`

```swift
//
//  SystemOpenAppTool.swift
//  Ora
//
//  Open applications by name
//

import Foundation
import AppKit

struct SystemOpenAppTool: Tool {
    let name = "system.open_app"
    let kind: ToolKind = .read  // No confirmation needed
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Open an application by name",
            parameters: [
                "app_name": ParameterSchema(type: "string", description: "Application name (e.g., 'Safari', 'Spotify')", format: nil)
            ],
            requiredParameters: ["app_name"]
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let appName = args["app_name"]?.stringValue, !appName.isEmpty else {
            throw ToolValidationError.missingParameter("app_name")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let appName = args["app_name"]?.stringValue else {
            throw ToolExecutionError.invalidArgument("App name required")
        }
        
        // Try to find and open the app
        let workspace = NSWorkspace.shared
        
        // Try common locations
        let searchPaths = [
            "/Applications/\(appName).app",
            "/Applications/\(appName)",
            "/System/Applications/\(appName).app",
            "/System/Applications/Utilities/\(appName).app"
        ]
        
        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                let config = NSWorkspace.OpenConfiguration()
                try await workspace.openApplication(at: url, configuration: config)
                return .success(
                    .object(["opened": .bool(true), "path": .string(path)]),
                    summary: "Opened \(appName)."
                )
            }
        }
        
        // Try using Launch Services
        if let appURL = workspace.urlForApplication(withBundleIdentifier: appName) {
            let config = NSWorkspace.OpenConfiguration()
            try await workspace.openApplication(at: appURL, configuration: config)
            return .success(
                .object(["opened": .bool(true)]),
                summary: "Opened \(appName)."
            )
        }
        
        // Try Spotlight search
        if let appURL = findAppByName(appName) {
            let config = NSWorkspace.OpenConfiguration()
            try await workspace.openApplication(at: appURL, configuration: config)
            return .success(
                .object(["opened": .bool(true)]),
                summary: "Opened \(appName)."
            )
        }
        
        throw ToolExecutionError.notFound("Application '\(appName)' not found")
    }
    
    private func findAppByName(_ name: String) -> URL? {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        
        // Check running apps first
        if let app = apps.first(where: { 
            $0.localizedName?.lowercased() == name.lowercased() 
        }) {
            return app.bundleURL
        }
        
        // Search Applications folder
        let appDir = URL(fileURLWithPath: "/Applications")
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: appDir,
            includingPropertiesForKeys: nil
        ) {
            if let match = contents.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased()
            }) {
                return match
            }
        }
        
        return nil
    }
}
```

### 3.2 Open URL Tool

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
            requiredParameters: ["url"]
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let urlString = args["url"]?.stringValue, !urlString.isEmpty else {
            throw ToolValidationError.missingParameter("url")
        }
        guard URL(string: urlString) != nil else {
            throw ToolValidationError.invalidFormat("url", "valid URL")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let urlString = args["url"]?.stringValue,
              let url = URL(string: urlString) else {
            throw ToolExecutionError.invalidArgument("Valid URL required")
        }
        
        // Ensure URL has a scheme
        var finalURL = url
        if url.scheme == nil {
            finalURL = URL(string: "https://\(urlString)") ?? url
        }
        
        let success = NSWorkspace.shared.open(finalURL)
        
        if success {
            return .success(
                .object(["opened": .bool(true), "url": .string(finalURL.absoluteString)]),
                summary: "Opened \(finalURL.host ?? urlString) in your browser."
            )
        } else {
            throw ToolExecutionError.failed("Failed to open URL")
        }
    }
}
```

---

## 4. Acceptance Criteria

- [ ] **AC-1:** Open app by name works for common apps
- [ ] **AC-2:** Open URL adds https:// if missing
- [ ] **AC-3:** Clear error if app not found
- [ ] **AC-4:** No confirmation required (read-only)

---

## 5. Implementation Checklist

- [ ] Create `SystemOpenAppTool.swift`
- [ ] Create `SystemOpenURLTool.swift`
- [ ] Register in `ToolRegistry`
- [ ] Test with various apps
- [ ] Test with various URL formats

---

## 6. Implementation Notes (From X.02 Learnings)

### Tool Result Context

System tools are simpler (no multi-step flows), but follow the same patterns:

1. **Return confirmation in JSON:** Include `opened: true` and relevant details (path, URL) so the LLM can confirm success to the user.

2. **Human summary for TTS:** Keep it brief and confirmatory ("Opened Safari", "Opening google.com in your browser").

3. **Error handling:** System tools can fail silently (app not found, URL invalid). Return clear errors that the LLM can relay naturally.
