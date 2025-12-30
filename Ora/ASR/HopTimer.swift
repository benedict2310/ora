//
//  HopTimer.swift
//  Ora
//
//  Precise timer for transcription hops.
//

import Foundation

/// Callback type for hop events
public typealias HopCallback = @Sendable () -> Void

/// Precise timer for transcription hops.
///
/// Provides accurate timing with minimal drift for streaming transcription.
/// Uses DispatchSource for precise scheduling with tight leeway.
///
/// ## Usage
///
/// ```swift
/// let timer = HopTimer(interval: 0.4)  // 400ms hops
///
/// timer.onHop = {
///     await processHop()
/// }
///
/// timer.start()
/// // ... later
/// timer.stop()
/// ```
public final class HopTimer: @unchecked Sendable {

    // MARK: - Properties

    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private var isRunning = false
    private let lock = NSLock()

    /// Callback invoked on each hop
    public var onHop: HopCallback?

    // MARK: - Statistics

    private var hopCount: Int = 0
    private var lastHopTime: Date?
    private var cumulativeDrift: TimeInterval = 0

    /// Number of hops fired
    public var totalHops: Int {
        lock.lock()
        defer { lock.unlock() }
        return hopCount
    }

    /// Average drift from expected interval
    public var averageDrift: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return hopCount > 0 ? cumulativeDrift / Double(hopCount) : 0
    }

    // MARK: - Initialization

    /// Create a hop timer with the specified interval
    /// - Parameters:
    ///   - interval: Time between hops in seconds
    ///   - queue: Queue for callbacks (defaults to user-interactive QoS)
    public init(
        interval: TimeInterval,
        queue: DispatchQueue = DispatchQueue(
            label: "com.ora.hoptimer",
            qos: .userInteractive
        )
    ) {
        self.interval = interval
        self.queue = queue
    }

    // MARK: - Control

    /// Start the timer
    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(10)  // Tight leeway for accuracy
        )

        timer.setEventHandler { [weak self] in
            self?.handleHop()
        }

        timer.resume()
        self.timer = timer
        isRunning = true
        hopCount = 0
        lastHopTime = nil
        cumulativeDrift = 0
    }

    /// Stop the timer
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        timer?.cancel()
        timer = nil
        isRunning = false
    }

    /// Check if timer is currently running
    public var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    // MARK: - Private

    private func handleHop() {
        let now = Date()

        lock.lock()
        if let last = lastHopTime {
            let actualInterval = now.timeIntervalSince(last)
            let drift = abs(actualInterval - interval)
            cumulativeDrift += drift
        }
        lastHopTime = now
        hopCount += 1
        lock.unlock()

        onHop?()
    }
}
