//
//  AppSettings.swift
//  Ora
//
//  Persistent app settings
//

import Foundation
import SwiftData

@Model
final class AppSettings {

    // MARK: - Properties

    /// Singleton key
    @Attribute(.unique) var id: String = "settings"

    /// Default calendar ID for new events
    var defaultCalendarID: String?

    /// Voice output enabled
    var voiceOutputEnabled: Bool = true

    /// Primary LLM model identifier
    var primaryLLMModel: String = "qwen2.5-7b-instruct-4bit"

    /// Last app update check
    var lastUpdateCheck: Date?

    /// Hotkey configuration (JSON)
    var hotkeyConfigData: Data?

    // MARK: - Initialization

    init() {}

    // MARK: - Hotkey Config

    var hotkeyConfig: HotkeyConfiguration {
        get {
            guard let data = hotkeyConfigData else { return .defaultHotkey }
            return (try? JSONDecoder().decode(HotkeyConfiguration.self, from: data)) ?? .defaultHotkey
        }
        set {
            hotkeyConfigData = try? JSONEncoder().encode(newValue)
        }
    }
}
