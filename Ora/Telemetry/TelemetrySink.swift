import Foundation

protocol TelemetrySink: Sendable {
    func record(_ event: TelemetryEvent) async
}

actor InMemoryTelemetrySink: TelemetrySink {
    private var storedEvents: [TelemetryEvent] = []

    func record(_ event: TelemetryEvent) async {
        self.storedEvents.append(event)
    }

    func snapshot() -> [TelemetryEvent] {
        self.storedEvents
    }
}
