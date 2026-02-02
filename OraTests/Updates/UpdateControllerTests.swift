//
//  UpdateControllerTests.swift
//  OraTests
//
//  Unit tests for Sparkle update controller
//

import XCTest
@testable import Ora

@MainActor
final class UpdateControllerTests: XCTestCase {

    func test_updateController_initializesFromUpdater() {
        let lastCheck = Date(timeIntervalSince1970: 12345)
        let driver = MockUpdateDriver(
            canCheckForUpdates: true,
            lastUpdateCheckDate: lastCheck,
            automaticallyChecksForUpdates: false,
            updateCheckInterval: UpdateCheckInterval.weekly.rawValue
        )

        let controller = UpdateController(updater: driver)

        XCTAssertEqual(controller.canCheckForUpdates, true)
        XCTAssertEqual(controller.lastUpdateCheck, lastCheck)
        XCTAssertEqual(controller.automaticallyChecksForUpdates, false)
        XCTAssertEqual(controller.updateCheckInterval, .weekly)
    }

    func test_updateController_checkForUpdates_callsDriver() {
        let driver = MockUpdateDriver(
            canCheckForUpdates: true,
            lastUpdateCheckDate: nil,
            automaticallyChecksForUpdates: true,
            updateCheckInterval: UpdateCheckInterval.daily.rawValue
        )

        let controller = UpdateController(updater: driver)

        XCTAssertEqual(driver.checkCallCount, 0)
        controller.checkForUpdates()
        XCTAssertEqual(driver.checkCallCount, 1)
    }

    func test_updateController_updatesFromDriverChange() {
        let driver = MockUpdateDriver(
            canCheckForUpdates: false,
            lastUpdateCheckDate: nil,
            automaticallyChecksForUpdates: true,
            updateCheckInterval: UpdateCheckInterval.daily.rawValue
        )

        let controller = UpdateController(updater: driver)
        XCTAssertEqual(controller.canCheckForUpdates, false)
        XCTAssertNil(controller.lastUpdateCheck)

        let newDate = Date(timeIntervalSince1970: 45678)
        driver.canCheckForUpdates = true
        driver.lastUpdateCheckDate = newDate
        driver.automaticallyChecksForUpdates = false
        driver.updateCheckInterval = UpdateCheckInterval.monthly.rawValue
        driver.notifyChange()

        XCTAssertEqual(controller.canCheckForUpdates, true)
        XCTAssertEqual(controller.lastUpdateCheck, newDate)
        XCTAssertEqual(controller.automaticallyChecksForUpdates, false)
        XCTAssertEqual(controller.updateCheckInterval, .monthly)
    }

    func test_updateController_settingPreferences_updatesDriver() {
        let driver = MockUpdateDriver(
            canCheckForUpdates: true,
            lastUpdateCheckDate: nil,
            automaticallyChecksForUpdates: true,
            updateCheckInterval: UpdateCheckInterval.daily.rawValue
        )

        let controller = UpdateController(updater: driver)

        controller.automaticallyChecksForUpdates = false
        XCTAssertEqual(driver.automaticallyChecksForUpdates, false)

        controller.updateCheckInterval = .weekly
        XCTAssertEqual(driver.updateCheckInterval, UpdateCheckInterval.weekly.rawValue)
    }
}
