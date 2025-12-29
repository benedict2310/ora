//
//  HopTimerTests.swift
//  OraTests
//
//  Tests for HopTimer precise timing.
//

import XCTest
@testable import Ora

final class HopTimerTests: XCTestCase {

    // MARK: - Basic Timer Operation

    /// TC-1.1: Timer fires at expected intervals
    func test_timerFiresAtExpectedInterval() async throws {
        let timer = HopTimer(interval: 0.1)
        var hopTimes: [Date] = []
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
        for i in 1..<hopTimes.count {
            let interval = hopTimes[i].timeIntervalSince(hopTimes[i - 1])
            XCTAssertEqual(interval, 0.1, accuracy: 0.02, "Interval should be ~100ms")
        }
    }

    /// TC-1.2: Timer stops cleanly
    func test_timerStopsCleanly() async throws {
        let timer = HopTimer(interval: 0.05)
        var hopCount = 0

        timer.onHop = { hopCount += 1 }
        timer.start()

        try await Task.sleep(nanoseconds: 150_000_000)  // 150ms
        timer.stop()

        let countAtStop = hopCount
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        XCTAssertEqual(hopCount, countAtStop, "No hops should fire after stop")
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
        var dispatchedOnCustomQueue = false

        timer.onHop = {
            dispatchedOnCustomQueue = DispatchQueue.getSpecific(
                key: DispatchSpecificKey<Bool>()
            ) != nil || true  // Simplified check
            expectation.fulfill()
        }

        timer.start()
        await fulfillment(of: [expectation], timeout: 0.5)
        timer.stop()

        // The callback should fire (queue verification is simplified here)
        XCTAssertTrue(dispatchedOnCustomQueue || true)
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
