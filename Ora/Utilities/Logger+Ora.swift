import OSLog

extension Logger {
    static let oraSubsystem = Bundle.main.bundleIdentifier ?? "com.ora.app"

    static func ora(category: String) -> Logger {
        return Logger(subsystem: Self.oraSubsystem, category: category)
    }
}
