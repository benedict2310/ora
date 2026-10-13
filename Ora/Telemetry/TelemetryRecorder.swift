import Foundation

enum TelemetryRecorderError: Error, Sendable, Equatable {
    case spanAlreadyClosed(TelemetrySpanToken)
}

actor TelemetryRecorder {
    private struct OpenSpan: Sendable, Equatable {
        let token: TelemetrySpanToken
        let startedAt: TelemetryTime
    }

    private let clock: any TelemetryClock
    private let sinks: [any TelemetrySink]
    private var nextSequenceNumber: Int = 1
    private var nextSpanIdentifier: Int = 1
    private var openSpans: [Int: OpenSpan] = [:]

    init(
        clock: any TelemetryClock = SystemTelemetryClock(),
        sinks: [any TelemetrySink] = []
    ) {
        self.clock = clock
        self.sinks = sinks
    }

    func record(
        _ name: TelemetryEventName,
        turnID: TelemetryTurnID? = nil,
        level: TelemetryLevel = .info,
        fields: [TelemetryField] = []
    ) async -> TelemetryEvent {
        let sequenceNumber = self.reserveSequenceNumber()

        let event = TelemetryEvent(
            name: name,
            turnID: turnID,
            sequenceNumber: sequenceNumber,
            time: await self.clock.now(),
            level: level,
            fields: fields
        )

        for sink in self.sinks {
            await sink.record(event)
        }

        return event
    }

    func beginSpan(
        _ kind: TelemetrySpanKind,
        turnID: TelemetryTurnID? = nil,
        level: TelemetryLevel = .info,
        fields: [TelemetryField] = []
    ) async -> TelemetrySpanToken {
        let token = TelemetrySpanToken(id: self.nextSpanIdentifier, kind: kind, turnID: turnID)
        self.nextSpanIdentifier += 1

        let startEvent = await self.record(
            kind.startedEventName,
            turnID: turnID,
            level: level,
            fields: self.fieldsWithSpanID(fields, token: token)
        )
        self.openSpans[token.id] = OpenSpan(token: token, startedAt: startEvent.time)

        return token
    }

    func endSpan(
        _ token: TelemetrySpanToken,
        level: TelemetryLevel = .info,
        fields: [TelemetryField] = []
    ) async throws -> TelemetryEvent {
        let openSpan = try self.closeSpan(token)
        return await self.recordTerminalSpanEvent(
            token.kind.completedEventName,
            openSpan: openSpan,
            level: level,
            fields: fields
        )
    }

    func failSpan(
        _ token: TelemetrySpanToken,
        level: TelemetryLevel = .error,
        fields: [TelemetryField] = []
    ) async throws -> TelemetryEvent {
        let openSpan = try self.closeSpan(token)
        return await self.recordTerminalSpanEvent(
            token.kind.failedEventName,
            openSpan: openSpan,
            level: level,
            fields: fields
        )
    }

    func cancelSpan(
        _ token: TelemetrySpanToken,
        level: TelemetryLevel = .notice,
        fields: [TelemetryField] = []
    ) async throws -> TelemetryEvent {
        let openSpan = try self.closeSpan(token)
        return await self.recordTerminalSpanEvent(
            token.kind.cancelledEventName,
            openSpan: openSpan,
            level: level,
            fields: fields
        )
    }

    func openSpanCount() -> Int {
        self.openSpans.count
    }

    private func closeSpan(_ token: TelemetrySpanToken) throws -> OpenSpan {
        guard let openSpan = self.openSpans[token.id], openSpan.token == token else {
            throw TelemetryRecorderError.spanAlreadyClosed(token)
        }
        self.openSpans.removeValue(forKey: token.id)
        return openSpan
    }

    private func recordTerminalSpanEvent(
        _ name: TelemetryEventName,
        openSpan: OpenSpan,
        level: TelemetryLevel,
        fields: [TelemetryField]
    ) async -> TelemetryEvent {
        let sequenceNumber = self.reserveSequenceNumber()
        let time = await self.clock.now()
        let event = TelemetryEvent(
            name: name,
            turnID: openSpan.token.turnID,
            sequenceNumber: sequenceNumber,
            time: time,
            level: level,
            fields: self.fieldsWithSpanID(fields, token: openSpan.token) + [
                TelemetryField(
                    key: "durationMilliseconds",
                    value: .integer(self.durationMilliseconds(from: openSpan.startedAt, to: time)),
                    visibility: .publicDebug
                )
            ]
        )

        for sink in self.sinks {
            await sink.record(event)
        }

        return event
    }

    private func reserveSequenceNumber() -> Int {
        let sequenceNumber = self.nextSequenceNumber
        self.nextSequenceNumber += 1
        return sequenceNumber
    }

    private func durationMilliseconds(from start: TelemetryTime, to end: TelemetryTime) -> Int {
        guard end.rawValue >= start.rawValue else {
            return 0
        }
        let duration = end.rawValue - start.rawValue
        return Int(min(duration, UInt64(Int.max)))
    }

    private func fieldsWithSpanID(
        _ fields: [TelemetryField],
        token: TelemetrySpanToken
    ) -> [TelemetryField] {
        fields + [TelemetryField(key: "spanID", value: .integer(token.id), visibility: .publicDebug)]
    }
}
