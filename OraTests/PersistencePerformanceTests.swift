//
//  PersistencePerformanceTests.swift
//  OraTests
//
//  Baseline performance guardrails for session message persistence.
//

import Foundation
import XCTest
@testable import Ora

final class PersistencePerformanceTests: XCTestCase {

    // MARK: - Constants

    private let baselineMessageCounts = [100, 500, 1000]
    private let baselineIterations = 8
    private let maxEncodeDecodeMillisecondsFor1000Messages = 100.0

    // MARK: - Baselines

    func test_persistencePerformance_encodeDecodeBaselines_100_500_1000_messages() throws {
        // Given
        var baselineSummaries: [String] = []

        // When
        for messageCount in self.baselineMessageCounts {
            let messages = self.makeMessages(count: messageCount)
            let encodeMeasurement = try self.measureDurations(iterations: self.baselineIterations) {
                _ = try JSONEncoder().encode(messages)
            }

            let encodedData = try JSONEncoder().encode(messages)
            let decodeMeasurement = try self.measureDurations(iterations: self.baselineIterations) {
                _ = try JSONDecoder().decode([Session.Message].self, from: encodedData)
            }

            let summary = String(
                format: "messages=%d encode_avg_ms=%.3f encode_max_ms=%.3f decode_avg_ms=%.3f decode_max_ms=%.3f",
                messageCount,
                encodeMeasurement.averageMilliseconds,
                encodeMeasurement.maxMilliseconds,
                decodeMeasurement.averageMilliseconds,
                decodeMeasurement.maxMilliseconds
            )
            baselineSummaries.append(summary)

            print("Persistence baseline: \(summary)")
        }

        // Then
        XCTAssertEqual(baselineSummaries.count, self.baselineMessageCounts.count)
    }

    func test_persistencePerformance_encodeDecode_1000Messages_completesUnder100Milliseconds() throws {
        // Given
        let messages = self.makeMessages(count: 1000)

        // When
        let start = DispatchTime.now().uptimeNanoseconds
        let encodedData = try JSONEncoder().encode(messages)
        _ = try JSONDecoder().decode([Session.Message].self, from: encodedData)
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000.0

        // Then
        XCTAssertLessThan(elapsedMilliseconds, self.maxEncodeDecodeMillisecondsFor1000Messages)
    }

    // MARK: - Helpers

    private func makeMessages(count: Int) -> [Session.Message] {
        let baseTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { index in
            Session.Message(
                id: UUID(),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "Persistence benchmark message \(index)",
                timestamp: baseTimestamp.addingTimeInterval(Double(index)),
                metadata: ["index": "\(index)"]
            )
        }
    }

    private func measureDurations(
        iterations: Int,
        operation: () throws -> Void
    ) throws -> DurationMeasurement {
        var elapsedMilliseconds: [Double] = []
        elapsedMilliseconds.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try operation()
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
            elapsedMilliseconds.append(Double(elapsedNanoseconds) / 1_000_000.0)
        }

        let average = elapsedMilliseconds.reduce(0, +) / Double(iterations)
        let maximum = elapsedMilliseconds.max() ?? 0
        return DurationMeasurement(
            averageMilliseconds: average,
            maxMilliseconds: maximum
        )
    }
}

private struct DurationMeasurement {
    let averageMilliseconds: Double
    let maxMilliseconds: Double
}
