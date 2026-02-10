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

/// Protocol for handling menu bar actions, enabling dependency injection for testing.
@MainActor
protocol StatusBarActionHandler: AnyObject {
    func handlePreferences()
    func handleOpenProviderSetup()
    func handleQuit()
}

/// Default action handler that performs actual app actions.
@MainActor
final class DefaultStatusBarActionHandler: StatusBarActionHandler {
    func handlePreferences() {
        PreferencesCoordinator.shared.showPreferences()
    }

    func handleOpenProviderSetup() {
        PreferencesCoordinator.shared.selectTab(.providers)
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
    private var defaultActionHandler: DefaultStatusBarActionHandler?
    private weak var injectedActionHandler: StatusBarActionHandler?
    private let updateChecker: UpdateChecking
    private let providerPreferencesViewModel: ProviderPreferencesViewModel
    private var modelRefreshTask: Task<Void, Never>?

    private(set) var state: State = .idle {
        didSet {
            self.updateIcon()
        }
    }

    // MARK: - Initialization

    init(
        actionHandler: StatusBarActionHandler? = nil,
        updateChecker: UpdateChecking? = nil,
        providerPreferencesViewModel: ProviderPreferencesViewModel? = nil
    ) {
        self.updateChecker = updateChecker ?? UpdateController.shared
        self.providerPreferencesViewModel = providerPreferencesViewModel ?? ProviderPreferencesViewModel()
        if let handler = actionHandler {
            self.injectedActionHandler = handler
        } else {
            self.defaultActionHandler = DefaultStatusBarActionHandler()
        }
        super.init()
        self.setupStatusItem()

        Task { @MainActor in
            await self.providerPreferencesViewModel.loadState()
            self.rebuildMenu()
        }
    }

    /// Returns the active action handler.
    private var actionHandler: StatusBarActionHandler? {
        self.injectedActionHandler ?? self.defaultActionHandler
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
        self.modelRefreshTask?.cancel()
        self.modelRefreshTask = nil

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

    /// Returns the menu item titles (including submenu items). Exposed for testing.
    var menuItemTitles: [String] {
        guard let menu = self.statusItem?.menu else { return [] }
        var titles: [String] = []
        for item in menu.items where !item.isSeparatorItem {
            titles.append(item.title)
            if let submenu = item.submenu {
                for subItem in submenu.items where !subItem.isSeparatorItem {
                    titles.append(subItem.title)
                }
            }
        }
        return titles
    }

    /// Returns the menu item key equivalents. Exposed for testing.
    var menuItemKeyEquivalents: [String: String] {
        var result: [String: String] = [:]
        for item in self.statusItem?.menu?.items ?? [] where !item.isSeparatorItem {
            result[item.title] = item.keyEquivalent
            if let submenu = item.submenu {
                for subItem in submenu.items where !subItem.isSeparatorItem {
                    result[subItem.title] = subItem.keyEquivalent
                }
            }
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

    /// Returns whether the setup connection item is present (checks submenu).
    var hasSetUpConnectionMenuItem: Bool {
        guard let menu = self.statusItem?.menu else { return false }
        for item in menu.items {
            if item.title == "Set Up Connection..." { return true }
            if let submenu = item.submenu {
                if submenu.items.contains(where: { $0.title == "Set Up Connection..." }) { return true }
            }
        }
        return false
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

    /// Simulates clicking Set Up Connection menu item.
    func simulateSetUpConnectionClick() {
        self.setUpConnectionClicked()
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

        button.image = self.iconForState(.idle)
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        self.statusItem?.menu = menu
        self.rebuildMenu()

        self.logger.debug("Status bar initialized")
    }

    private func rebuildMenu() {
        guard let menu = self.statusItem?.menu else { return }

        menu.removeAllItems()

        let selectionState = self.providerPreferencesViewModel.modelSelectionMenuState

        // Build LLM Model submenu
        let modelSubmenu = NSMenu()
        let modelMenuItem = NSMenuItem(
            title: "LLM Model",
            action: nil,
            keyEquivalent: ""
        )
        modelMenuItem.submenu = modelSubmenu

        // Current selection header
        let currentItem = NSMenuItem(
            title: "\(selectionState.activeProvider.displayName): \(selectionState.activeModelDisplayName)",
            action: nil,
            keyEquivalent: ""
        )
        currentItem.isEnabled = false
        modelSubmenu.addItem(currentItem)

        for (index, section) in selectionState.sections.enumerated() {
            if index > 0 || !section.options.isEmpty {
                modelSubmenu.addItem(NSMenuItem.separator())
            }

            for option in section.options {
                let item = NSMenuItem(
                    title: "\(section.title): \(option.displayName)",
                    action: #selector(self.modelSelectionClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.state = option.isSelected ? .on : .off
                item.representedObject = [
                    "provider": option.provider.rawValue,
                    "modelIdentifier": option.identifier,
                ] as NSDictionary
                modelSubmenu.addItem(item)
            }
        }

        if selectionState.showsSetupAction {
            modelSubmenu.addItem(NSMenuItem.separator())
            let setupItem = NSMenuItem(
                title: "Set Up Connection...",
                action: #selector(self.setUpConnectionClicked),
                keyEquivalent: ""
            )
            setupItem.target = self
            modelSubmenu.addItem(setupItem)
        }

        if let unavailableMessage = selectionState.openAIUnavailableMessage {
            let noteItem = NSMenuItem(title: unavailableMessage, action: nil, keyEquivalent: "")
            noteItem.isEnabled = false
            modelSubmenu.addItem(noteItem)
        }

        menu.addItem(modelMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(self.preferencesClicked), keyEquivalent: ","))

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(self.checkForUpdatesClicked),
            keyEquivalent: ""
        )
        checkUpdatesItem.isEnabled = self.updateChecker.canCheckForUpdates
        menu.addItem(checkUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        let conversationModeItem = NSMenuItem(
            title: "Conversation Mode",
            action: #selector(self.conversationModeClicked),
            keyEquivalent: ""
        )
        conversationModeItem.state = self.isConversationModeEnabled ? .on : .off
        menu.addItem(conversationModeItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Ora", action: #selector(self.quitClicked), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
    }

    private func scheduleMenuModelRefresh() {
        self.modelRefreshTask?.cancel()
        self.modelRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.providerPreferencesViewModel.refreshModelAvailability(forceRefresh: false)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.rebuildMenu()
            }
        }
    }

    private func updateIcon() {
        guard let button = self.statusItem?.button else { return }
        button.image = self.iconForState(self.state)
        if case .error = self.state {
            button.image?.isTemplate = false
        } else {
            button.image?.isTemplate = true
        }
    }

    private func iconForState(_ state: State) -> NSImage? {
        let assetName = Self.assetName(for: state)
        if let customImage = NSImage(named: assetName) {
            customImage.isTemplate = true
            return customImage
        }

        let symbolName = Self.symbolName(for: state)
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ora")?
            .withSymbolConfiguration(config)
    }

    // MARK: - Actions

    @objc private func preferencesClicked() {
        self.showPreferences()
    }

    @objc private func setUpConnectionClicked() {
        self.actionHandler?.handleOpenProviderSetup()
    }

    @objc private func checkForUpdatesClicked() {
        self.updateChecker.checkForUpdates()
    }

    @objc private func conversationModeClicked(_ sender: NSMenuItem) {
        let newState = !self.isConversationModeEnabled
        self.setConversationModeEnabled(newState)
        sender.state = newState ? .on : .off
    }

    @objc private func modelSelectionClicked(_ sender: NSMenuItem) {
        guard
            let payload = sender.representedObject as? NSDictionary,
            let providerRaw = payload["provider"] as? String,
            let modelIdentifier = payload["modelIdentifier"] as? String,
            let provider = LLMProviderType(rawValue: providerRaw)
        else {
            self.logger.error("STATUSBAR_MODEL_SELECTION_INVALID_PAYLOAD")
            return
        }

        Task { @MainActor in
            await self.providerPreferencesViewModel.selectModel(
                provider: provider,
                identifier: modelIdentifier
            )
            self.rebuildMenu()
        }
    }

    @objc private func quitClicked() {
        self.logger.info("Quit requested by user")
        self.actionHandler?.handleQuit()
    }

    // MARK: - Menu Delegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        self.rebuildMenu()
        self.scheduleMenuModelRefresh()
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
