//
//  PreferencesTests.swift
//  OraTests
//
//  Unit tests for Preferences components
//

import XCTest
@testable import Ora

// MARK: - PreferencesTab Tests

final class PreferencesTabTests: XCTestCase {

    // MARK: - Tab Properties Tests

    func test_allCases_hasFiveTabs() {
        XCTAssertEqual(PreferencesTab.allCases.count, 5)
    }

    func test_allCases_containsExpectedTabs() {
        let allCases = PreferencesTab.allCases
        XCTAssertTrue(allCases.contains(.general))
        XCTAssertTrue(allCases.contains(.providers))
        XCTAssertTrue(allCases.contains(.models))
        XCTAssertTrue(allCases.contains(.permissions))
        XCTAssertTrue(allCases.contains(.about))
    }

    func test_title_general_returnsGeneral() {
        XCTAssertEqual(PreferencesTab.general.title, "General")
    }

    func test_title_models_returnsModels() {
        XCTAssertEqual(PreferencesTab.models.title, "Models")
    }

    func test_title_providers_returnsProviders() {
        XCTAssertEqual(PreferencesTab.providers.title, "Providers")
    }

    func test_title_permissions_returnsPermissions() {
        XCTAssertEqual(PreferencesTab.permissions.title, "Permissions")
    }

    func test_title_about_returnsAbout() {
        XCTAssertEqual(PreferencesTab.about.title, "About")
    }

    func test_icon_general_returnsGear() {
        XCTAssertEqual(PreferencesTab.general.icon, "gear")
    }

    func test_icon_models_returnsCpu() {
        XCTAssertEqual(PreferencesTab.models.icon, "cpu")
    }

    func test_icon_providers_returnsICloud() {
        XCTAssertEqual(PreferencesTab.providers.icon, "icloud")
    }

    func test_icon_permissions_returnsLockShield() {
        XCTAssertEqual(PreferencesTab.permissions.icon, "lock.shield")
    }

    func test_icon_about_returnsInfoCircle() {
        XCTAssertEqual(PreferencesTab.about.icon, "info.circle")
    }

    func test_rawValue_matchesExpected() {
        XCTAssertEqual(PreferencesTab.general.rawValue, "general")
        XCTAssertEqual(PreferencesTab.providers.rawValue, "providers")
        XCTAssertEqual(PreferencesTab.models.rawValue, "models")
        XCTAssertEqual(PreferencesTab.permissions.rawValue, "permissions")
        XCTAssertEqual(PreferencesTab.about.rawValue, "about")
    }
}

// MARK: - PreferencesCoordinator Tests

@MainActor
final class PreferencesCoordinatorTests: XCTestCase {

    // MARK: - Singleton Tests

    func test_shared_returnsSameInstance() {
        let instance1 = PreferencesCoordinator.shared
        let instance2 = PreferencesCoordinator.shared
        XCTAssertTrue(instance1 === instance2, "Shared should always return the same instance")
    }

    // MARK: - Tab Selection Tests

    func test_initialSelectedTab_isGeneral() {
        let coordinator = PreferencesCoordinator.shared
        // Reset to known state
        coordinator.selectedTab = .general
        XCTAssertEqual(coordinator.selectedTab, .general)
    }

    func test_selectedTab_canBeChanged() {
        let coordinator = PreferencesCoordinator.shared

        coordinator.selectedTab = .providers
        XCTAssertEqual(coordinator.selectedTab, .providers)

        coordinator.selectedTab = .models
        XCTAssertEqual(coordinator.selectedTab, .models)

        coordinator.selectedTab = .permissions
        XCTAssertEqual(coordinator.selectedTab, .permissions)

        coordinator.selectedTab = .about
        XCTAssertEqual(coordinator.selectedTab, .about)

        // Reset to general
        coordinator.selectedTab = .general
    }

    func test_selectTab_updatesSelectedTab() {
        let coordinator = PreferencesCoordinator.shared

        coordinator.selectTab(.providers)
        XCTAssertEqual(coordinator.selectedTab, .providers)

        coordinator.selectTab(.models)
        XCTAssertEqual(coordinator.selectedTab, .models)

        coordinator.selectTab(.permissions)
        XCTAssertEqual(coordinator.selectedTab, .permissions)

        // Cleanup - close any opened window
        coordinator.closePreferences()
        coordinator.selectedTab = .general
    }

    // MARK: - Window Management Tests

    func test_showPreferences_canBeCalledSafely() {
        let coordinator = PreferencesCoordinator.shared
        // Should not crash
        coordinator.showPreferences()
        // Cleanup
        coordinator.closePreferences()
    }

    func test_closePreferences_canBeCalledSafely() {
        let coordinator = PreferencesCoordinator.shared
        // Should not crash even if no window is open
        coordinator.closePreferences()
    }

    func test_showPreferences_thenClose_doesNotCrash() {
        let coordinator = PreferencesCoordinator.shared
        coordinator.showPreferences()
        coordinator.closePreferences()
    }

    func test_showPreferences_calledMultipleTimes_doesNotCreateDuplicates() {
        let coordinator = PreferencesCoordinator.shared

        // Open multiple times
        coordinator.showPreferences()
        coordinator.showPreferences()
        coordinator.showPreferences()

        // Should still work fine
        coordinator.closePreferences()
    }
}

// MARK: - AuditFilter Tests

final class AuditFilterTests: XCTestCase {

    func test_allCases_hasFourFilters() {
        XCTAssertEqual(AuditFilter.allCases.count, 4)
    }

    func test_allCases_containsExpectedFilters() {
        let allCases = AuditFilter.allCases
        XCTAssertTrue(allCases.contains(.all))
        XCTAssertTrue(allCases.contains(.tools))
        XCTAssertTrue(allCases.contains(.errors))
        XCTAssertTrue(allCases.contains(.confirmations))
    }

    func test_displayName_all_returnsAll() {
        XCTAssertEqual(AuditFilter.all.displayName, "All")
    }

    func test_displayName_tools_returnsTools() {
        XCTAssertEqual(AuditFilter.tools.displayName, "Tools")
    }

    func test_displayName_errors_returnsErrors() {
        XCTAssertEqual(AuditFilter.errors.displayName, "Errors")
    }

    func test_displayName_confirmations_returnsConfirmations() {
        XCTAssertEqual(AuditFilter.confirmations.displayName, "Confirmations")
    }

    func test_rawValue_matchesExpected() {
        XCTAssertEqual(AuditFilter.all.rawValue, "all")
        XCTAssertEqual(AuditFilter.tools.rawValue, "tools")
        XCTAssertEqual(AuditFilter.errors.rawValue, "errors")
        XCTAssertEqual(AuditFilter.confirmations.rawValue, "confirmations")
    }
}

// MARK: - Integration Tests

@MainActor
final class PreferencesIntegrationTests: XCTestCase {

    func test_statusBarController_showPreferences_opensWindow() {
        let mockHandler = MockStatusBarActionHandler()
        let controller = StatusBarController(actionHandler: mockHandler)

        controller.showPreferences()

        XCTAssertEqual(mockHandler.preferencesCallCount, 1)
        controller.shutdown()
    }
}
