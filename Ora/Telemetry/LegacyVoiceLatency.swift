import Foundation

public protocol LegacyVoiceLatencyClock: Sendable {
    func now() -> UInt64
}

public struct SystemLegacyVoiceLatencyClock: LegacyVoiceLatencyClock {
    public func now() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000)
    }
}

public struct LegacyVoiceLatencyTurn: Sendable, Equatable {
    fileprivate let id: UUID
    public var turnID: UUID { self.id }
}

public struct LegacyVoiceLatencyAttempt: Sendable, Equatable {
    fileprivate let turnID: UUID
    fileprivate let attemptID: UUID
    public var speechAttemptID: UUID { self.attemptID }
    public var voiceTurnID: UUID { self.turnID }
}

public enum LegacyVoiceLatencyBackend: String, Sendable {
    case kokoro, avSpeech
}

/// Neither boundary establishes physical audibility.
public enum LegacyVoiceLatencyBoundary: String, Sendable {
    case scheduled, utteranceStarted
}

public enum LegacyVoiceLatencyOutcome: String, Sendable {
    case success, cancelled, error
}

public enum LegacyVoiceCompletionBoundary: String, Sendable {
    case dataConsumed, utteranceFinished, unavailable
}

/// Source callbacks synchronously capture the same monotonic clock under the
/// lock. Delivery is serialized separately; no callback waits for a log sink.
/// Only the current turn and its active attempt are retained.
public final class LegacyVoiceLatencyObserver: @unchecked Sendable {
    private struct Trace {
        let attempt: LegacyVoiceLatencyAttempt
        let requestedAt: UInt64
        var firstPCMAt: UInt64?
        var boundaryAt: UInt64?
        var backend: LegacyVoiceLatencyBackend?
        var boundary: LegacyVoiceLatencyBoundary?
        var fallbackFinishedAt: UInt64?
        var consumedAt: UInt64?
        var streamFinishedAt: UInt64?
        var pendingBuffers: Set<UUID> = []
    }

    private let clock: any LegacyVoiceLatencyClock
    private let sink: any TelemetrySink
    private let lock = NSLock()
    private var turn: LegacyVoiceLatencyTurn?
    private var acceptedAt: UInt64?
    private var asrFinalAt: UInt64?
    private var trace: Trace?
    private var sequence = 0
    private var delivery: Task<Void, Never>?

    init(clock: any LegacyVoiceLatencyClock = SystemLegacyVoiceLatencyClock(),
         sink: any TelemetrySink = OSTelemetrySink()) {
        self.clock = clock
        self.sink = sink
    }

    func beginTurn() -> LegacyVoiceLatencyTurn {
        self.lock.withLock {
            self.close(.cancelled, reason: "turn_replaced", boundary: .unavailable)
            let turn = LegacyVoiceLatencyTurn(id: UUID())
            self.turn = turn
            self.acceptedAt = nil
            self.asrFinalAt = nil
            return turn
        }
    }

    func reset(reason: String = "reset") {
        self.lock.withLock {
            self.close(.cancelled, reason: reason, boundary: .unavailable)
            self.turn = nil
            self.acceptedAt = nil
            self.asrFinalAt = nil
        }
    }

    func beginAttempt(for turn: LegacyVoiceLatencyTurn) -> LegacyVoiceLatencyAttempt {
        self.lock.withLock {
            let attempt = LegacyVoiceLatencyAttempt(turnID: turn.id, attemptID: UUID())
            guard self.turn == turn else { return attempt }
            self.close(.cancelled, reason: "attempt_replaced", boundary: .unavailable)
            let trace = Trace(attempt: attempt, requestedAt: self.clock.now())
            self.trace = trace
            self.emit(.voiceLatencyAttemptStarted, trace: trace, time: trace.requestedAt, fields: [])
            return attempt
        }
    }

    /// A queued source startup must check eligibility before replacing output.
    func isActive(_ attempt: LegacyVoiceLatencyAttempt) -> Bool {
        self.lock.withLock { self.trace?.attempt == attempt }
    }

    func acceptedTranscript(for turn: LegacyVoiceLatencyTurn) {
        self.lock.withLock {
            guard self.turn == turn, self.acceptedAt == nil else { return }
            self.acceptedAt = self.clock.now()
        }
    }

    func asrFinalReceived(for turn: LegacyVoiceLatencyTurn) {
        self.lock.withLock {
            guard self.turn == turn, self.asrFinalAt == nil else { return }
            self.asrFinalAt = self.clock.now()
        }
    }

    func firstPCMChunkReceived(for attempt: LegacyVoiceLatencyAttempt) {
        self.lock.withLock {
            guard var trace = self.trace, trace.attempt == attempt, trace.firstPCMAt == nil else { return }
            let time = self.clock.now()
            trace.firstPCMAt = time
            self.trace = trace
            self.emit(.voiceLatencyFirstPCMReceived, trace: trace, time: time, fields: [
                self.string("backend", "kokoro"),
                self.duration("ttsRequestToFirstPCMChunkMilliseconds", from: trace.requestedAt, to: time)
            ])
        }
    }

    func playbackBoundary(for attempt: LegacyVoiceLatencyAttempt,
                          backend: LegacyVoiceLatencyBackend, boundary: LegacyVoiceLatencyBoundary) {
        self.lock.withLock {
            guard var trace = self.trace, trace.attempt == attempt, trace.boundaryAt == nil else { return }
            let time = self.clock.now()
            trace.boundaryAt = time
            trace.backend = backend
            trace.boundary = boundary
            self.trace = trace
            self.emit(.voiceLatencyBoundaryObserved, trace: trace, time: time, fields: self.fields(trace))
        }
    }

    func complete(_ outcome: LegacyVoiceLatencyOutcome, for attempt: LegacyVoiceLatencyAttempt,
                  reason: String, boundary: LegacyVoiceCompletionBoundary = .unavailable) {
        self.lock.withLock {
            guard self.trace?.attempt == attempt else { return }
            self.close(outcome, reason: reason, boundary: boundary)
        }
    }

    func bufferScheduled(_ id: UUID, for attempt: LegacyVoiceLatencyAttempt) {
        self.lock.withLock {
            guard self.trace?.attempt == attempt else { return }
            self.trace?.pendingBuffers.insert(id)
        }
    }

    /// Called directly by the backend callback, before its bookkeeping actor hop.
    func bufferConsumed(_ id: UUID, for attempt: LegacyVoiceLatencyAttempt) {
        self.lock.withLock {
            guard self.trace?.attempt == attempt,
                  self.trace?.pendingBuffers.remove(id) != nil else { return }
            self.trace?.consumedAt = self.clock.now()
        }
    }

    func streamFinished(for attempt: LegacyVoiceLatencyAttempt) {
        self.lock.withLock {
            guard self.trace?.attempt == attempt, self.trace?.streamFinishedAt == nil else { return }
            self.trace?.streamFinishedAt = self.clock.now()
        }
    }

    func fallbackFinished(for attempt: LegacyVoiceLatencyAttempt) {
        self.lock.withLock {
            guard self.trace?.attempt == attempt, self.trace?.fallbackFinishedAt == nil else { return }
            self.trace?.fallbackFinishedAt = self.clock.now()
        }
    }

    func playbackCompleted(for attempt: LegacyVoiceLatencyAttempt) {
        self.lock.withLock {
            guard let trace = self.trace, trace.attempt == attempt else { return }
            let boundary: LegacyVoiceCompletionBoundary = trace.fallbackFinishedAt != nil ? .utteranceFinished :
                (trace.consumedAt != nil ? .dataConsumed : .unavailable)
            let sourceTimes = trace.fallbackFinishedAt != nil ? [trace.consumedAt, trace.fallbackFinishedAt] :
                [trace.streamFinishedAt, trace.consumedAt]
            let sourceTime = sourceTimes.compactMap { $0 }.max()
            self.close(.success, reason: "stream_completed", boundary: boundary, time: sourceTime)
        }
    }

    /// Deterministic drain for tests and shutdown; not a wall-clock sleep.
    func flush() async {
        let delivery = self.lock.withLock { self.delivery }
        await delivery?.value
    }

    private func close(_ outcome: LegacyVoiceLatencyOutcome, reason: String,
                       boundary: LegacyVoiceCompletionBoundary, time: UInt64? = nil) {
        guard let trace = self.trace else { return }
        self.trace = nil // Late callbacks and duplicate terminals are now inert.
        let time = time ?? self.clock.now()
        self.emit(.voiceLatencyAttemptCompleted, trace: trace, time: time, fields: self.fields(trace) + [
            self.string("outcome", outcome.rawValue), self.string("reason", reason),
            self.string("completionBoundary", boundary.rawValue),
            self.duration("ttsRequestToCompletionMilliseconds", from: trace.requestedAt, to: time)
        ])
    }

    private func fields(_ trace: Trace) -> [TelemetryField] {
        var fields = [self.string("backend", trace.backend?.rawValue ?? "unavailable"),
                      self.string("boundary", trace.boundary?.rawValue ?? "unavailable")]
        if let pcm = trace.firstPCMAt {
            fields.append(self.duration("ttsRequestToFirstPCMChunkMilliseconds", from: trace.requestedAt, to: pcm))
        }
        if let time = trace.boundaryAt {
            fields.append(self.duration("ttsRequestToPlaybackBoundaryMilliseconds", from: trace.requestedAt, to: time))
            if let accepted = self.acceptedAt, accepted <= time {
                fields.append(self.duration("acceptedTranscriptToPlaybackBoundaryMilliseconds", from: accepted, to: time))
            }
            if let final = self.asrFinalAt, final <= time {
                fields.append(self.duration("asrFinalToPlaybackBoundaryMilliseconds", from: final, to: time))
            }
        }
        return fields
    }

    private func duration(_ key: String, from: UInt64, to: UInt64) -> TelemetryField {
        TelemetryField(key: key, value: .integer(Int(min(to >= from ? to - from : 0, UInt64(Int.max)))), visibility: .publicDebug)
    }

    private func string(_ key: String, _ value: String) -> TelemetryField {
        TelemetryField(key: key, value: .string(value), visibility: .publicDebug)
    }

    /// Called only under lock so task chaining preserves source order.
    private func emit(_ name: TelemetryEventName, trace: Trace, time: UInt64, fields: [TelemetryField]) {
        self.sequence += 1
        let event = TelemetryEvent(name: name,
            turnID: TelemetryTurnID(trace.attempt.turnID.uuidString), sequenceNumber: self.sequence,
            time: TelemetryTime(rawValue: time), level: name == .voiceLatencyAttemptCompleted ? .notice : .info,
            fields: fields + [self.string("speechAttemptID", trace.attempt.attemptID.uuidString)])
        let previous = self.delivery
        let sink = self.sink
        self.delivery = Task {
            await previous?.value
            await sink.record(event)
        }
    }
}

extension LegacyVoiceLatencyAttempt {
    func complete(by observer: LegacyVoiceLatencyObserver, outcome: LegacyVoiceLatencyOutcome,
                  reason: String, boundary: LegacyVoiceCompletionBoundary = .unavailable) {
        observer.complete(outcome, for: self, reason: reason, boundary: boundary)
    }
}

public struct LegacyVoiceLatencyContext: Sendable {
    let attempt: LegacyVoiceLatencyAttempt
    let observer: LegacyVoiceLatencyObserver
    init(attempt: LegacyVoiceLatencyAttempt, observer: LegacyVoiceLatencyObserver) {
        self.attempt = attempt
        self.observer = observer
    }
}
