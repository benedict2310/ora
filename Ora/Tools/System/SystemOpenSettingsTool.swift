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
                "pane": ParameterSchema(type: "string", description: "Settings pane to open (optional)")
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
