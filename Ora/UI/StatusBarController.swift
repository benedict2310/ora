//
//  StatusBarController.swift
//  Ora
//
//  Menu bar icon and dropdown menu management
//

import AppKit
import os

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
final class StatusBarController {

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

    private(set) var state: State = .idle {
        didSet {
            self.updateIcon()
        }
    }

    // MARK: - Initialization

    init(actionHandler: StatusBarActionHandler? = nil) {
        if let handler = actionHandler {
            self.injectedActionHandler = handler
        } else {
            self.defaultActionHandler = DefaultStatusBarActionHandler()
        }
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

        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(self.preferencesClicked), keyEquivalent: ","))
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

    @objc private func quitClicked() {
        self.logger.info("Quit requested by user")
        self.actionHandler?.handleQuit()
    }
}
