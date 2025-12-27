//
//  StatusBarController.swift
//  Ora
//
//  Menu bar icon and dropdown menu management
//

import AppKit
import os

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

    private(set) var state: State = .idle {
        didSet {
            self.updateIcon()
        }
    }

    // MARK: - Initialization

    init() {
        self.setupStatusItem()
    }

    // MARK: - Public API

    func setState(_ newState: State) {
        guard self.state != newState else { return }
        self.state = newState
        self.logger.debug("Status bar state: \(String(describing: newState))")
    }

    func showPreferences() {
        // Will be implemented in F.06
        self.logger.debug("Show preferences requested")
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
        let symbolName: String
        switch state {
        case .idle:
            symbolName = "circle"
        case .listening:
            symbolName = "circle.fill"
        case .thinking:
            symbolName = "circle.dotted"
        case .speaking:
            symbolName = "speaker.wave.2.fill"
        case .error:
            symbolName = "exclamationmark.triangle"
        case .setupRequired:
            symbolName = "arrow.down.circle"
        }

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
        NSApp.terminate(nil)
    }
}
