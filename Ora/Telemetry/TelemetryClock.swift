import Foundation

protocol TelemetryClock: Sendable {
    func now() async -> TelemetryTime
}

struct SystemTelemetryClock: TelemetryClock {
    func now() async -> TelemetryTime {
        TelemetryTime(rawValue: UInt64(ProcessInfo.processInfo.systemUptime * 1_000))
    }
}

actor TestTelemetryClock: TelemetryClock {
    private var nextValue: UInt64
    private let step: UInt64

    init(start: UInt64, step: UInt64) {
        self.nextValue = start
        self.step = step
    }

    func now() async -> TelemetryTime {
        let currentValue = self.nextValue
        self.nextValue += self.step
        return TelemetryTime(rawValue: currentValue)
    }
}
