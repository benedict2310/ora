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
    var primaryLLMModel: String = "qwen3-4b-instruct-4bit"

    /// Last app update check
    var lastUpdateCheck: Date?

    /// Hotkey configuration (JSON)
    var hotkeyConfigData: Data?

    /// Conversation mode: combines silence detection + auto-listen (AC-6)
    /// Using originalName to preserve existing user settings during migration
    @Attribute(originalName: "autoListenEnabled")
    var conversationModeEnabled: Bool = true

    /// Silence timeout in seconds (0.5s - 2.0s range, default 1.0s)
    /// Controls how long to wait after last speech before auto-submitting
    var silenceTimeout: Double = 1.0

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
