import Foundation

enum OraConstants {
    enum Timing {
        static let pipelineErrorRecoveryDelay: TimeInterval = 3.0
        static let pipelineFollowUpAutoListenDelay: TimeInterval = 0.5
        static let memoryWatcherDebounceInterval: TimeInterval = 0.75
        static let memoryWatcherEndWriteDelay = Duration.milliseconds(200)
        static let memoryWatcherReopenDelay = Duration.milliseconds(50)
        static let memoryWatcherDebounceGranularityMilliseconds = 1_000.0
        static let fluidVADRetryCooldown: TimeInterval = 5 * 60
    }
}
