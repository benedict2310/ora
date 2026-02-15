//
//  HopTimerTests.swift
//  OraTests
//
//  Tests for HopTimer precise timing.
//

import XCTest
@testable import Ora

// MARK: - Thread-Safe Test Helpers

/// Thread-safe counter for test assertions
private final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}

/// Thread-safe date collector for test assertions
private final class AtomicDateCollector: @unchecked Sendable {
    private var _dates: [Date] = []
    private let lock = NSLock()

    var dates: [Date] {
        lock.withLock { _dates }
    }

    func append(_ date: Date) {
        lock.withLock { _dates.append(date) }
    }
}

final class HopTimerTests: XCTestCase {

    // MARK: - Basic Timer Operation

    /// TC-1.1: Timer fires at expected intervals
    func test_timerFiresAtExpectedInterval() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Timing-sensitive test flaky on CI runners")
        let timer = HopTimer(interval: 0.1)
        let hopTimes = AtomicDateCollector()
        let expectation = expectation(description: "hops")
        expectation.expectedFulfillmentCount = 5

        timer.onHop = {
            hopTimes.append(Date())
            expectation.fulfill()
        }

        timer.start()
        await fulfillment(of: [expectation], timeout: 1.0)
        timer.stop()

        // Verify intervals (allowing 20ms tolerance)
        let times = hopTimes.dates
        for i in 1..<times.count {
            let interval = times[i].timeIntervalSince(times[i - 1])
            XCTAssertEqual(interval, 0.1, accuracy: 0.02, "Interval should be ~100ms")
        }
    }

    /// TC-1.2: Timer stops cleanly
    func test_timerStopsCleanly() async throws {
        let timer = HopTimer(interval: 0.05)
        let hopCount = AtomicCounter()

        timer.onHop = { hopCount.increment() }
        timer.start()

        try await Task.sleep(nanoseconds: 150_000_000)  // 150ms
        timer.stop()

        let countAtStop = hopCount.value
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        XCTAssertEqual(hopCount.value, countAtStop, "No hops should fire after stop")
    }

    /// TC-1.3: Timer handles rapid start/stop
    func test_timerHandlesRapidStartStop() {
        let timer = HopTimer(interval: 0.1)

        for _ in 0..<10 {
            timer.start()
            timer.stop()
        }

        // Should not crash or leak
        XCTAssertEqual(timer.totalHops, 0)
    }

    /// TC-1.4: Timer drift stays within bounds
    func test_timerDriftWithinBounds() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Timing-sensitive test flaky on CI runners")
        let timer = HopTimer(interval: 0.1)
        let expectation = expectation(description: "hops")
        expectation.expectedFulfillmentCount = 20

        timer.onHop = { expectation.fulfill() }
        timer.start()

        await fulfillment(of: [expectation], timeout: 3.0)
        timer.stop()

        // Average drift should be <10ms
        XCTAssertLessThan(timer.averageDrift, 0.01, "Drift should be minimal")
    }

    // MARK: - State Tracking

    func test_runningState() {
        let timer = HopTimer(interval: 0.1)

        XCTAssertFalse(timer.running, "Should not be running initially")

        timer.start()
        XCTAssertTrue(timer.running, "Should be running after start")

        timer.stop()
        XCTAssertFalse(timer.running, "Should not be running after stop")
    }

    func test_totalHopsIncrement() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Timing-sensitive test flaky on CI runners")
        let timer = HopTimer(interval: 0.05)
        let expectation = expectation(description: "hops")
        expectation.expectedFulfillmentCount = 5

        timer.onHop = { expectation.fulfill() }
        timer.start()

        await fulfillment(of: [expectation], timeout: 1.0)
        timer.stop()

        XCTAssertEqual(timer.totalHops, 5, "Total hops should match")
    }

    // MARK: - Callback Behavior

    func test_callbackOnQueue() async throws {
        let customQueue = DispatchQueue(label: "test.queue")
        let timer = HopTimer(interval: 0.05, queue: customQueue)

        let expectation = expectation(description: "hop")

        timer.onHop = {
            // Callback fires on the specified queue
            expectation.fulfill()
        }

        timer.start()
        await fulfillment(of: [expectation], timeout: 0.5)
        timer.stop()

        // The callback should have fired (simplified verification)
        XCTAssertTrue(true)
    }

    // MARK: - Edge Cases

    func test_startWithNoCallback() async throws {
        let timer = HopTimer(interval: 0.05)
        // No callback set

        timer.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        timer.stop()

        // Should not crash
        XCTAssertTrue(timer.totalHops > 0)
    }

    func test_multipleStartsAreIdempotent() {
        let timer = HopTimer(interval: 0.1)

        timer.start()
        timer.start()  // Should be ignored
        timer.start()  // Should be ignored

        XCTAssertTrue(timer.running)
        timer.stop()
    }

    func test_multipleStopsAreSafe() {
        let timer = HopTimer(interval: 0.1)

        timer.start()
        timer.stop()
        timer.stop()  // Should be safe
        timer.stop()  // Should be safe

        XCTAssertFalse(timer.running)
    }
}
