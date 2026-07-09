import Foundation

enum TelemetryRecorderError: Error, Sendable, Equatable {
    case spanAlreadyClosed(TelemetrySpanToken)
}

actor TelemetryRecorder {
    private let clock: any TelemetryClock
    private let sinks: [any TelemetrySink]
    private var nextSequenceNumber: Int = 1
    private var nextSpanIdentifier: Int = 1
    private var openSpans: [Int: TelemetrySpanToken] = [:]

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
        let sequenceNumber = self.nextSequenceNumber
        self.nextSequenceNumber += 1

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
        self.openSpans[token.id] = token

        _ = await self.record(
            kind.startedEventName,
            turnID: turnID,
            level: level,
            fields: self.fieldsWithSpanID(fields, token: token)
        )

        return token
    }

    func endSpan(
        _ token: TelemetrySpanToken,
        level: TelemetryLevel = .info,
        fields: [TelemetryField] = []
    ) async throws -> TelemetryEvent {
        try self.closeSpan(token)
        return await self.record(
            token.kind.completedEventName,
            turnID: token.turnID,
            level: level,
            fields: self.fieldsWithSpanID(fields, token: token)
        )
    }

    func failSpan(
        _ token: TelemetrySpanToken,
        level: TelemetryLevel = .error,
        fields: [TelemetryField] = []
    ) async throws -> TelemetryEvent {
        try self.closeSpan(token)
        return await self.record(
            token.kind.failedEventName,
            turnID: token.turnID,
            level: level,
            fields: self.fieldsWithSpanID(fields, token: token)
        )
    }

    func cancelSpan(
        _ token: TelemetrySpanToken,
        level: TelemetryLevel = .notice,
        fields: [TelemetryField] = []
    ) async throws -> TelemetryEvent {
        try self.closeSpan(token)
        return await self.record(
            token.kind.cancelledEventName,
            turnID: token.turnID,
            level: level,
            fields: self.fieldsWithSpanID(fields, token: token)
        )
    }

    func openSpanCount() -> Int {
        self.openSpans.count
    }

    private func closeSpan(_ token: TelemetrySpanToken) throws {
        guard self.openSpans[token.id] == token else {
            throw TelemetryRecorderError.spanAlreadyClosed(token)
        }
        self.openSpans.removeValue(forKey: token.id)
    }

    private func fieldsWithSpanID(
        _ fields: [TelemetryField],
        token: TelemetrySpanToken
    ) -> [TelemetryField] {
        fields + [TelemetryField(key: "spanID", value: .integer(token.id), visibility: .publicDebug)]
    }
}
