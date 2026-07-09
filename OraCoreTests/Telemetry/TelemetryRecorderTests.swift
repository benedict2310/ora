import XCTest
@testable import OraCore

final class TelemetryRecorderTests: XCTestCase {
    func test_recorderAssignsDeterministicSequenceNumbersAndSharedTurnID() async throws {
        let clock = TestTelemetryClock(start: 1_000, step: 10)
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: clock, sinks: [sink])
        let turnID = TelemetryTurnID("turn-1")

        let first = await recorder.record(
            .turnStarted,
            turnID: turnID,
            fields: [TelemetryField(key: "source", value: .string("text"), visibility: .publicDebug)]
        )
        let second = await recorder.record(
            .inputTextReceived,
            turnID: turnID,
            fields: [TelemetryField(key: "characterCount", value: .integer(24), visibility: .publicDebug)]
        )
        let events = await sink.snapshot()

        XCTAssertEqual(first.sequenceNumber, 1)
        XCTAssertEqual(second.sequenceNumber, 2)
        XCTAssertEqual(first.turnID, turnID)
        XCTAssertEqual(second.turnID, turnID)
        XCTAssertEqual(first.time, TelemetryTime(rawValue: 1_000))
        XCTAssertEqual(second.time, TelemetryTime(rawValue: 1_010))
        XCTAssertEqual(events, [first, second])
    }

    func test_concurrentRecordsReserveUniqueSequenceNumbersBeforeAwaitingClock() async {
        let clock = TestTelemetryClock(start: 10_000, step: 1)
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: clock, sinks: [sink])
        let turnID = TelemetryTurnID("turn-concurrent")

        await withTaskGroup(of: TelemetryEvent.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    await recorder.record(.inputTextReceived, turnID: turnID)
                }
            }
        }

        let events = await sink.snapshot()
        let sequenceNumbers = events.map(\.sequenceNumber)

        XCTAssertEqual(Set(sequenceNumbers).count, 25)
        XCTAssertEqual(sequenceNumbers.sorted(), Array(1...25))
    }

    func test_recorderBalancesSpanStartEndFailureAndCancel() async throws {
        let clock = TestTelemetryClock(start: 2_000, step: 5)
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: clock, sinks: [sink])
        let turnID = TelemetryTurnID("turn-span")

        let turnSpan = await recorder.beginSpan(.turn, turnID: turnID)
        _ = try await recorder.endSpan(turnSpan)

        let playbackSpan = await recorder.beginSpan(.ttsPlayback, turnID: turnID)
        _ = try await recorder.cancelSpan(playbackSpan)

        let actionSpan = await recorder.beginSpan(.actionExecution, turnID: turnID)
        _ = try await recorder.failSpan(actionSpan, fields: [
            TelemetryField(key: "reason", value: .string("permission_denied"), visibility: .publicDebug)
        ])

        let events = await sink.snapshot()
        let openSpanCount = await recorder.openSpanCount()

        XCTAssertEventNames(
            events,
            [
                .turnStarted,
                .turnCompleted,
                .ttsPlaybackStarted,
                .ttsPlaybackCancelled,
                .actionExecutionStarted,
                .actionExecutionFailed
            ]
        )
        XCTAssertEqual(events.map(\.sequenceNumber), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(openSpanCount, 0)
    }

    func test_recorderRejectsDoubleClosingSpanWithoutEmittingDuplicateTerminalEvent() async throws {
        let clock = TestTelemetryClock(start: 3_000, step: 5)
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: clock, sinks: [sink])
        let span = await recorder.beginSpan(.actionExecution, turnID: "turn-double-close")

        _ = try await recorder.endSpan(span)

        await XCTAssertThrowsErrorAsync(try await recorder.endSpan(span)) { error in
            XCTAssertEqual(error as? TelemetryRecorderError, .spanAlreadyClosed(span))
        }

        let events = await sink.snapshot()
        XCTAssertEventNames(events, [.actionExecutionStarted, .actionExecutionCompleted])
    }

    func test_recorderRejectsTerminalEventAfterDifferentTerminalEvent() async throws {
        let clock = TestTelemetryClock(start: 4_000, step: 5)
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: clock, sinks: [sink])
        let span = await recorder.beginSpan(.ttsSynthesis, turnID: "turn-terminal")

        _ = try await recorder.failSpan(span)

        await XCTAssertThrowsErrorAsync(try await recorder.cancelSpan(span)) { error in
            XCTAssertEqual(error as? TelemetryRecorderError, .spanAlreadyClosed(span))
        }

        let events = await sink.snapshot()
        XCTAssertEventNames(events, [.ttsSynthesisStarted, .ttsSynthesisFailed])
    }

    func test_recorderRejectsUnknownSpanTokenWithoutEmittingTerminalEvent() async {
        let clock = TestTelemetryClock(start: 5_000, step: 5)
        let sink = InMemoryTelemetrySink()
        let recorder = TelemetryRecorder(clock: clock, sinks: [sink])
        let unknownToken = TelemetrySpanToken(id: 999, kind: .turn, turnID: "unknown-turn")

        await XCTAssertThrowsErrorAsync(try await recorder.endSpan(unknownToken)) { error in
            XCTAssertEqual(error as? TelemetryRecorderError, .spanAlreadyClosed(unknownToken))
        }

        let events = await sink.snapshot()
        XCTAssertTrue(events.isEmpty)
    }
}
