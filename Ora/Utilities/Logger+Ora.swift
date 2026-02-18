import OSLog

extension Logger {
    static func ora(category: String) -> Logger {
        return Logger(subsystem: OraLog.subsystem, category: category)
    }
}
