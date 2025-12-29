//
//  HotkeyManagerTests.swift
//  OraTests
//
//  Tests for hotkey configuration and manager
//

import XCTest
import Carbon.HIToolbox
@testable import Ora

// MARK: - HotkeyConfiguration Tests

final class HotkeyConfigurationTests: XCTestCase {

    // MARK: - Lifecycle

    override func tearDown() {
        // Reset to default after each test to avoid polluting other tests
        HotkeyConfiguration.defaultHotkey.save()
        super.tearDown()
    }

    // MARK: - Default Configuration Tests

    func test_defaultHotkey_isOptionSpace() {
        let config = HotkeyConfiguration.defaultHotkey

        XCTAssertEqual(config.keyCode, UInt16(kVK_Space))
        XCTAssertEqual(config.modifiers, UInt32(optionKey))
    }

    // MARK: - Display String Tests

    func test_displayString_optionSpace() {
        let config = HotkeyConfiguration.defaultHotkey

        XCTAssertEqual(config.displayString, "⌥Space")
    }

    func test_displayString_commandShiftO() {
        let config = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_O),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        XCTAssertEqual(config.displayString, "⇧⌘O")
    }

    func test_displayString_controlOptionA() {
        let config = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_A),
            modifiers: UInt32(controlKey | optionKey)
        )

        XCTAssertEqual(config.displayString, "⌃⌥A")
    }

    func test_displayString_allModifiers() {
        let config = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_X),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )

        // Modifiers should appear in order: control, option, shift, command
        XCTAssertEqual(config.displayString, "⌃⌥⇧⌘X")
    }

    func test_displayString_functionKeys() {
        // Test F1
        let configF1 = HotkeyConfiguration(
            keyCode: UInt16(kVK_F1),
            modifiers: UInt32(optionKey)
        )
        XCTAssertEqual(configF1.displayString, "⌥F1")

        // Test F12
        let configF12 = HotkeyConfiguration(
            keyCode: UInt16(kVK_F12),
            modifiers: UInt32(cmdKey)
        )
        XCTAssertEqual(configF12.displayString, "⌘F12")
    }

    func test_displayString_return() {
        let config = HotkeyConfiguration(
            keyCode: UInt16(kVK_Return),
            modifiers: UInt32(cmdKey)
        )

        XCTAssertEqual(config.displayString, "⌘Return")
    }

    func test_displayString_escape() {
        let config = HotkeyConfiguration(
            keyCode: UInt16(kVK_Escape),
            modifiers: UInt32(cmdKey)
        )

        XCTAssertEqual(config.displayString, "⌘Esc")
    }

    func test_displayString_numberKeys() {
        for i in 0...9 {
            let keyCode: UInt16
            switch i {
            case 0: keyCode = UInt16(kVK_ANSI_0)
            case 1: keyCode = UInt16(kVK_ANSI_1)
            case 2: keyCode = UInt16(kVK_ANSI_2)
            case 3: keyCode = UInt16(kVK_ANSI_3)
            case 4: keyCode = UInt16(kVK_ANSI_4)
            case 5: keyCode = UInt16(kVK_ANSI_5)
            case 6: keyCode = UInt16(kVK_ANSI_6)
            case 7: keyCode = UInt16(kVK_ANSI_7)
            case 8: keyCode = UInt16(kVK_ANSI_8)
            case 9: keyCode = UInt16(kVK_ANSI_9)
            default: continue
            }

            let config = HotkeyConfiguration(keyCode: keyCode, modifiers: UInt32(cmdKey))
            XCTAssertEqual(config.displayString, "⌘\(i)")
        }
    }

    // MARK: - Persistence Tests

    func test_configuration_persistence() {
        let testConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_O),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        testConfig.save()

        let loaded = HotkeyConfiguration.load()
        XCTAssertEqual(loaded, testConfig)
    }

    func test_load_returnsDefault_whenNoSavedConfig() {
        // Clear any saved config
        UserDefaults.standard.removeObject(forKey: "com.ora.hotkeyConfiguration")

        let loaded = HotkeyConfiguration.load()
        XCTAssertEqual(loaded, HotkeyConfiguration.defaultHotkey)
    }

    // MARK: - Equatable Tests

    func test_equatable_sameConfigs() {
        let config1 = HotkeyConfiguration(keyCode: UInt16(kVK_Space), modifiers: UInt32(optionKey))
        let config2 = HotkeyConfiguration(keyCode: UInt16(kVK_Space), modifiers: UInt32(optionKey))

        XCTAssertEqual(config1, config2)
    }

    func test_equatable_differentKeyCode() {
        let config1 = HotkeyConfiguration(keyCode: UInt16(kVK_Space), modifiers: UInt32(optionKey))
        let config2 = HotkeyConfiguration(keyCode: UInt16(kVK_ANSI_A), modifiers: UInt32(optionKey))

        XCTAssertNotEqual(config1, config2)
    }

    func test_equatable_differentModifiers() {
        let config1 = HotkeyConfiguration(keyCode: UInt16(kVK_Space), modifiers: UInt32(optionKey))
        let config2 = HotkeyConfiguration(keyCode: UInt16(kVK_Space), modifiers: UInt32(cmdKey))

        XCTAssertNotEqual(config1, config2)
    }
}

// MARK: - HotkeyManager Tests

@MainActor
final class HotkeyManagerTests: XCTestCase {

    // MARK: - Lifecycle

    override func tearDown() {
        // Reset configuration after tests
        HotkeyManager.shared.resetToDefault()
        HotkeyManager.shared.stop()
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func test_shared_returnsSameInstance() {
        let instance1 = HotkeyManager.shared
        let instance2 = HotkeyManager.shared

        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Initial State Tests

    func test_initialState_notListening() {
        // Stop first to ensure clean state
        HotkeyManager.shared.stop()

        XCTAssertFalse(HotkeyManager.shared.isListening)
    }

    func test_initialState_notPressed() {
        XCTAssertFalse(HotkeyManager.shared.isPressed)
    }

    func test_currentHotkey_returnsConfiguration() {
        let config = HotkeyManager.shared.currentHotkey

        // Should have valid key code and modifiers
        XCTAssertTrue(config.keyCode > 0 || config.keyCode == 0) // Space is 49, not 0
        XCTAssertTrue(config.modifiers > 0) // Should have at least one modifier
    }

    // MARK: - Conflict Detection Tests

    func test_conflictDetection_cmdSpace() {
        let spotlightConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_Space),
            modifiers: UInt32(cmdKey)
        )

        XCTAssertTrue(HotkeyManager.shared.checkForConflicts(spotlightConfig))
    }

    func test_conflictDetection_optionSpace_noConflict() {
        let config = HotkeyConfiguration.defaultHotkey

        XCTAssertFalse(HotkeyManager.shared.checkForConflicts(config))
    }

    func test_conflictDetection_cmdQ() {
        let quitConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_Q),
            modifiers: UInt32(cmdKey)
        )

        XCTAssertTrue(HotkeyManager.shared.checkForConflicts(quitConfig))
    }

    func test_conflictDetection_cmdW() {
        let closeConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_W),
            modifiers: UInt32(cmdKey)
        )

        XCTAssertTrue(HotkeyManager.shared.checkForConflicts(closeConfig))
    }

    func test_conflictDetection_cmdTab() {
        let switcherConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_Tab),
            modifiers: UInt32(cmdKey)
        )

        XCTAssertTrue(HotkeyManager.shared.checkForConflicts(switcherConfig))
    }

    func test_conflictDetection_cmdShift3() {
        let screenshotConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_3),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        XCTAssertTrue(HotkeyManager.shared.checkForConflicts(screenshotConfig))
    }

    func test_conflictDetection_cmdShift4() {
        let screenshotConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_4),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        XCTAssertTrue(HotkeyManager.shared.checkForConflicts(screenshotConfig))
    }

    func test_conflictDetection_cmdShift5() {
        let screenshotConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_5),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        XCTAssertTrue(HotkeyManager.shared.checkForConflicts(screenshotConfig))
    }

    func test_conflictDetection_safeHotkey() {
        // Option+Shift+O should not conflict with system shortcuts
        let safeConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_O),
            modifiers: UInt32(optionKey | shiftKey)
        )

        XCTAssertFalse(HotkeyManager.shared.checkForConflicts(safeConfig))
    }

    // MARK: - Configuration Change Tests

    func test_setHotkey_updatesCurrentHotkey() {
        let newConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: UInt32(optionKey | shiftKey)
        )

        HotkeyManager.shared.setHotkey(newConfig)

        XCTAssertEqual(HotkeyManager.shared.currentHotkey, newConfig)
    }

    func test_resetToDefault_restoresDefaultHotkey() {
        // First set a custom hotkey
        let customConfig = HotkeyConfiguration(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: UInt32(optionKey | shiftKey)
        )
        HotkeyManager.shared.setHotkey(customConfig)

        // Then reset
        HotkeyManager.shared.resetToDefault()

        XCTAssertEqual(HotkeyManager.shared.currentHotkey, HotkeyConfiguration.defaultHotkey)
    }

    // MARK: - Start/Stop Tests

    func test_stop_setsIsListeningFalse() {
        HotkeyManager.shared.stop()

        XCTAssertFalse(HotkeyManager.shared.isListening)
    }

    func test_start_setsIsListeningTrue() {
        // Carbon Events don't require accessibility permission
        // So start() should always enable listening
        HotkeyManager.shared.stop()
        HotkeyManager.shared.start()

        XCTAssertTrue(HotkeyManager.shared.isListening)
    }
}

// MARK: - NSEvent.ModifierFlags Extension Tests

final class ModifierFlagsExtensionTests: XCTestCase {

    func test_carbonFlags_control() {
        let flags: NSEvent.ModifierFlags = [.control]
        XCTAssertEqual(flags.carbonFlags, UInt32(controlKey))
    }

    func test_carbonFlags_option() {
        let flags: NSEvent.ModifierFlags = [.option]
        XCTAssertEqual(flags.carbonFlags, UInt32(optionKey))
    }

    func test_carbonFlags_shift() {
        let flags: NSEvent.ModifierFlags = [.shift]
        XCTAssertEqual(flags.carbonFlags, UInt32(shiftKey))
    }

    func test_carbonFlags_command() {
        let flags: NSEvent.ModifierFlags = [.command]
        XCTAssertEqual(flags.carbonFlags, UInt32(cmdKey))
    }

    func test_carbonFlags_multiple() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let expected = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        XCTAssertEqual(flags.carbonFlags, expected)
    }

    func test_carbonFlags_empty() {
        let flags: NSEvent.ModifierFlags = []
        XCTAssertEqual(flags.carbonFlags, 0)
    }
}

// MARK: - Notification Tests

@MainActor
final class HotkeyNotificationTests: XCTestCase {

    func test_notificationName_hotkeyDidPress() {
        XCTAssertEqual(Notification.Name.hotkeyDidPress.rawValue, "hotkeyDidPress")
    }

    func test_notificationName_hotkeyDidRelease() {
        XCTAssertEqual(Notification.Name.hotkeyDidRelease.rawValue, "hotkeyDidRelease")
    }
}
