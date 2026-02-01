//
//  StatusBarController.swift
//  Ora
//
//  Menu bar icon and dropdown menu management
//

import AppKit
import os
import SwiftData

// MARK: - Action Handler Protocol

/// Protocol for handling menu bar actions, enabling dependency injection for testing
@MainActor
protocol StatusBarActionHandler: AnyObject {
    func handlePreferences()
    func handleQuit()
}

/// Default action handler that performs actual app actions
@MainActor
final class DefaultStatusBarActionHandler: StatusBarActionHandler {
    func handlePreferences() {
        PreferencesCoordinator.shared.showPreferences()
    }

    func handleQuit() {
        NSApp.terminate(nil)
    }
}

// MARK: - StatusBarController

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    // MARK: - Types

    enum State: Equatable, Sendable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)
        case setupRequired
    }

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let logger = Logger(subsystem: "com.ora.app", category: "StatusBar")
    /// Strong reference to default handler, weak reference to injected handler
    private var defaultActionHandler: DefaultStatusBarActionHandler?
    private weak var injectedActionHandler: StatusBarActionHandler?
    private let updateChecker: UpdateChecking

    private(set) var state: State = .idle {
        didSet {
            self.updateIcon()
        }
    }

    // MARK: - Initialization

    init(actionHandler: StatusBarActionHandler? = nil, updateChecker: UpdateChecking? = nil) {
        self.updateChecker = updateChecker ?? UpdateController.shared
        if let handler = actionHandler {
            self.injectedActionHandler = handler
        } else {
            self.defaultActionHandler = DefaultStatusBarActionHandler()
        }
        super.init()
        self.setupStatusItem()
    }

    /// Returns the active action handler
    private var actionHandler: StatusBarActionHandler? {
        injectedActionHandler ?? defaultActionHandler
    }

    // MARK: - Public API

    func setState(_ newState: State) {
        guard self.state != newState else { return }
        self.state = newState
        self.logger.debug("Status bar state: \(String(describing: newState))")
    }

    func showPreferences() {
        self.actionHandler?.handlePreferences()
    }

    /// Removes the status item from the menu bar. Called during cleanup.
    func shutdown() {
        if let item = self.statusItem {
            NSStatusBar.system.removeStatusItem(item)
            self.statusItem = nil
            self.logger.debug("Status bar removed")
        }
    }

    // MARK: - Internal (Testable)

    /// Returns the custom asset name for a given state.
    static func assetName(for state: State) -> String {
        switch state {
        case .idle:
            return "menubar-idle"
        case .listening:
            return "menubar-listening"
        case .thinking:
            return "menubar-thinking"
        case .speaking:
            return "menubar-speaking"
        case .error:
            return "menubar-error"
        case .setupRequired:
            return "menubar-setup"
        }
    }

    /// Returns the SF Symbol name for a given state (fallback). Exposed for testing.
    static func symbolName(for state: State) -> String {
        switch state {
        case .idle:
            return "circle"
        case .listening:
            return "circle.fill"
        case .thinking:
            return "circle.dotted"
        case .speaking:
            return "speaker.wave.2.fill"
        case .error:
            return "exclamationmark.triangle"
        case .setupRequired:
            return "arrow.down.circle"
        }
    }

    /// Returns the menu item titles. Exposed for testing.
    var menuItemTitles: [String] {
        return self.statusItem?.menu?.items.compactMap { $0.isSeparatorItem ? nil : $0.title } ?? []
    }

    /// Returns the menu item key equivalents. Exposed for testing.
    var menuItemKeyEquivalents: [String: String] {
        var result: [String: String] = [:]
        for item in self.statusItem?.menu?.items ?? [] where !item.isSeparatorItem {
            result[item.title] = item.keyEquivalent
        }
        return result
    }

    /// Returns the state of the Conversation Mode menu item. Exposed for testing.
    var conversationModeMenuItemState: NSControl.StateValue? {
        return self.statusItem?.menu?.items.first(where: { $0.title == "Conversation Mode" })?.state
    }

    /// Returns the enabled state of the Check for Updates menu item. Exposed for testing.
    var checkForUpdatesMenuItemEnabled: Bool? {
        return self.statusItem?.menu?.items.first(where: { $0.title == "Check for Updates..." })?.isEnabled
    }

    /// Simulates clicking the Conversation Mode menu item. Exposed for testing.
    func simulateConversationModeToggle() {
        guard let menuItem = self.statusItem?.menu?.items.first(where: { $0.title == "Conversation Mode" }) else {
            return
        }
        self.conversationModeClicked(menuItem)
    }

    /// Simulates clicking the Check for Updates menu item. Exposed for testing.
    func simulateCheckForUpdates() {
        self.checkForUpdatesClicked()
    }

    /// Triggers menu update delegate method. Exposed for testing.
    func triggerMenuUpdate() {
        guard let menu = self.statusItem?.menu else { return }
        self.menuNeedsUpdate(menu)
    }

    // MARK: - Private Setup

    private func setupStatusItem() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = self.statusItem?.button else {
            self.logger.error("Failed to create status bar button")
            return
        }

        // Set initial icon
        button.image = self.iconForState(.idle)
        button.image?.isTemplate = true

        // Create menu
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(self.preferencesClicked), keyEquivalent: ","))
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(self.checkForUpdatesClicked), keyEquivalent: "")
        checkUpdatesItem.isEnabled = self.updateChecker.canCheckForUpdates
        menu.addItem(checkUpdatesItem)
        menu.addItem(NSMenuItem.separator())
        
        let conversationModeItem = NSMenuItem(title: "Conversation Mode", action: #selector(self.conversationModeClicked), keyEquivalent: "")
        conversationModeItem.state = self.isConversationModeEnabled ? .on : .off
        menu.addItem(conversationModeItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Ora", action: #selector(self.quitClicked), keyEquivalent: "q"))

        // Set targets
        for item in menu.items {
            item.target = self
        }

        self.statusItem?.menu = menu

        self.logger.debug("Status bar initialized")
    }

    private func updateIcon() {
        guard let button = self.statusItem?.button else { return }
        button.image = self.iconForState(self.state)
        // Use template mode for all states except error
        if case .error = self.state {
            button.image?.isTemplate = false
        } else {
            button.image?.isTemplate = true
        }
    }

    private func iconForState(_ state: State) -> NSImage? {
        // Prefer custom asset from asset catalog
        let assetName = Self.assetName(for: state)
        if let customImage = NSImage(named: assetName) {
            customImage.isTemplate = true
            return customImage
        }

        // Fall back to SF Symbol
        let symbolName = Self.symbolName(for: state)
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ora")?
            .withSymbolConfiguration(config)
    }

    // MARK: - Actions

    @objc private func preferencesClicked() {
        self.showPreferences()
    }

    @objc private func checkForUpdatesClicked() {
        self.updateChecker.checkForUpdates()
    }
    
    @objc private func conversationModeClicked(_ sender: NSMenuItem) {
        let newState = !self.isConversationModeEnabled
        self.setConversationModeEnabled(newState)
        sender.state = newState ? .on : .off
    }

    @objc private func quitClicked() {
        self.logger.info("Quit requested by user")
        self.actionHandler?.handleQuit()
    }
    
    // MARK: - Menu Delegate
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let item = menu.items.first(where: { $0.title == "Check for Updates..." }) {
            item.isEnabled = self.updateChecker.canCheckForUpdates
        }
        if let item = menu.items.first(where: { $0.title == "Conversation Mode" }) {
            item.state = self.isConversationModeEnabled ? .on : .off
        }
    }
    
    // MARK: - Private Helpers
    
    private var isConversationModeEnabled: Bool {
        return PersistenceManager.shared.settings.conversationModeEnabled
    }

    private func setConversationModeEnabled(_ enabled: Bool) {
        PersistenceManager.shared.updateSettings { settings in
            settings.conversationModeEnabled = enabled
        }
    }
}
