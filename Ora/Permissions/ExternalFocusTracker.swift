//
//  ExternalFocusTracker.swift
//  Ora
//
//  Tracks when tools are performing operations that will cause focus loss
//  (e.g., opening apps, URLs, Finder). Prevents session cancellation during
//  these operations while allowing the external app to retain focus.
//

import Foundation
import os

extension Notification.Name {
    static let externalFocusOperationDidEnd = Notification.Name("externalFocusOperationDidEnd")
}

@MainActor
final class ExternalFocusTracker {

    // MARK: - Singleton

    static let shared = ExternalFocusTracker()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "ExternalFocusTracker")
    private var activeOperationCount: Int = 0

    var isExternalOperationActive: Bool {
        self.activeOperationCount > 0
    }

    // MARK: - Init

    private init() {}

    // MARK: - Tracking

    func beginExternalOperation() {
        self.activeOperationCount += 1
        self.logger.debug("External focus operation began (count: \(self.activeOperationCount))")
    }

    func endExternalOperation() {
        guard self.activeOperationCount > 0 else {
            self.logger.warning("endExternalOperation called with no active operations")
            return
        }

        self.activeOperationCount -= 1
        self.logger.debug("External focus operation ended (count: \(self.activeOperationCount))")

        if self.activeOperationCount == 0 {
            NotificationCenter.default.post(name: .externalFocusOperationDidEnd, object: nil)
        }
    }

    /// Execute an async operation that may cause focus loss, with proper tracking.
    /// The operation is wrapped in begin/end calls automatically.
    ///
    /// Note: Includes a small delay after the operation to account for async focus
    /// changes that occur after NSWorkspace operations return.
    func withExternalOperation<T>(_ operation: () async throws -> T) async rethrows -> T {
        self.beginExternalOperation()
        let result = try await operation()
        // Add delay to keep tracking active while focus change propagates
        // NSWorkspace.open() returns immediately but focus changes async
        try? await Task.sleep(for: .milliseconds(500))
        self.endExternalOperation()
        return result
    }
}
