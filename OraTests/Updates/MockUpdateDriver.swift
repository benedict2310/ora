//
//  MockUpdateDriver.swift
//  OraTests
//
//  Test double for update driver
//

import Foundation
@testable import Ora

@MainActor
final class MockUpdateDriver: UpdateDriver {
    var canCheckForUpdates: Bool
    var lastUpdateCheckDate: Date?
    var automaticallyChecksForUpdates: Bool
    var updateCheckInterval: TimeInterval
    var checkCallCount = 0
    private var changeHandler: (() -> Void)?

    init(
        canCheckForUpdates: Bool,
        lastUpdateCheckDate: Date?,
        automaticallyChecksForUpdates: Bool,
        updateCheckInterval: TimeInterval
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.lastUpdateCheckDate = lastUpdateCheckDate
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.updateCheckInterval = updateCheckInterval
    }

    func checkForUpdates() {
        self.checkCallCount += 1
    }

    func observeChanges(_ handler: @escaping () -> Void) {
        self.changeHandler = handler
    }

    func notifyChange() {
        self.changeHandler?()
    }
}
