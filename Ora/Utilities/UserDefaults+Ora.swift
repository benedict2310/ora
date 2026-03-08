import Foundation

extension UserDefaults {
    enum OraKey {
        static let selectedLLMProvider = "com.ora.selectedLLMProvider"
        static let selectedAnthropicModel = "com.ora.selectedAnthropicModel"
        static let selectedOpenAIModel = "com.ora.selectedOpenAIModel"
        static let selectedOpenAIModelIdentifier = "com.ora.selectedOpenAIModelIdentifier"
        static let openAIDiscoveredModelIdentifiers = "com.ora.openAI.discoveredModelIdentifiers"
        static let openAIDiscoveredModels = "com.ora.openAI.discoveredModels"

        static let voiceOutputEnabled = "com.ora.voiceOutputEnabled"
        static let defaultCalendarID = "com.ora.defaultCalendarID"
        static let setupComplete = "com.ora.setupComplete"
        static let hotkeyConfiguration = "com.ora.hotkeyConfiguration"
    }

    var oraVoiceOutputEnabled: Bool {
        get {
            if self.object(forKey: OraKey.voiceOutputEnabled) == nil {
                return true
            }
            return self.bool(forKey: OraKey.voiceOutputEnabled)
        }
        set {
            self.set(newValue, forKey: OraKey.voiceOutputEnabled)
        }
    }

    var oraDefaultCalendarID: String {
        get {
            return self.string(forKey: OraKey.defaultCalendarID) ?? ""
        }
        set {
            self.set(newValue, forKey: OraKey.defaultCalendarID)
        }
    }

    var oraSetupComplete: Bool {
        get {
            return self.bool(forKey: OraKey.setupComplete)
        }
        set {
            self.set(newValue, forKey: OraKey.setupComplete)
        }
    }

    var oraHotkeyConfigurationData: Data? {
        get {
            return self.data(forKey: OraKey.hotkeyConfiguration)
        }
        set {
            self.set(newValue, forKey: OraKey.hotkeyConfiguration)
        }
    }
}
