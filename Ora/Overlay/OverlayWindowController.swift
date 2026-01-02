//
//  OverlayWindowController.swift
//  Ora
//
//  Manages the floating overlay window
//

import AppKit
import SwiftUI
import os

@MainActor
final class OverlayWindowController {

    // MARK: - Singleton

    static let shared = OverlayWindowController()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "OverlayWindow")
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

    private var escapeMonitor: Any?

    /// Current overlay mode
    var mode: OverlayMode {
        get { self.viewModel.mode }
        set { self.viewModel.mode = newValue }
    }

    /// View model for external updates
    var model: OverlayViewModel {
        self.viewModel
    }

    /// Whether the overlay is currently visible
    var isVisible: Bool {
        self.panel?.isVisible ?? false
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Show the overlay window
    func show() {
        if self.panel == nil {
            self.createPanel()
        }

        guard let panel = self.panel else {
            self.logger.error("Failed to create panel")
            return
        }

        // Position the panel
        self.positionPanel()
        
        // Show the window - set alpha directly to ensure visibility
        // Note: NSAnimationContext.runAnimationGroup was unreliable in Release builds
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        
        // Ensure app is active to receive input (required for accessory apps)
        NSApp.activate(ignoringOtherApps: true)

        // Add dismiss monitors
        self.addDismissMonitors()

        self.logger.debug("Overlay shown")
    }

    /// Hide the overlay window
    func hide(animated: Bool = true) {
        guard let panel = self.panel else { return }

        // Remove dismiss monitors
        self.removeDismissMonitors()

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor [weak self] in
                    panel.orderOut(nil)
                    self?.viewModel.reset()
                }
            }
        } else {
            panel.orderOut(nil)
            self.viewModel.reset()
        }

        self.logger.debug("Overlay hidden")
    }

    // MARK: - Private

    private func createPanel() {
        let contentView = OverlayView()
            .environmentObject(self.viewModel)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(NSSize(width: 400, height: 300))

        // Create floating panel
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        // Enable key events for keyboard navigation
        // We want it to become key immediately when shown
        panel.becomesKeyOnlyIfNeeded = false

        self.panel = panel
        self.logger.debug("Overlay panel created")
    }

    private func positionPanel() {
        guard let panel = self.panel, let screen = NSScreen.main else { return }

        // Position in upper-center of screen
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.midX - (panelSize.width / 2)
        let y = screenFrame.maxY - panelSize.height - 100 // 100pt from top

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Dismiss Monitors

    private func addDismissMonitors() {
        // Local keyboard monitor (when our panel has focus)
        self.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            if event.keyCode == 53 { // Escape key
                // Cancel the pipeline session (which will hide the overlay)
                SimplePipelineController.shared.cancel()
                return nil // Consume the event
            }
            
            if event.keyCode == 36 { // Enter key
                // Check state and decide action
                switch self.viewModel.mode {
                case .listening:
                    // Stop recording and submit
                    SimplePipelineController.shared.submitTranscript()
                    return nil
                    
                case .awaitingFollowUp:
                    // Start follow-up recording
                    SimplePipelineController.shared.startFollowUp()
                    return nil
                    
                case .thinking, .responding:
                    // Ignore Enter during processing
                    return nil
                    
                default:
                    // Let other cases pass through (e.g. confirming proposals)
                    break
                }
            }
            
            return event
        }
    }

    private func removeDismissMonitors() {
        if let monitor = self.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            self.escapeMonitor = nil
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a tool proposal is confirmed by the user
    static let proposalConfirmed = Notification.Name("proposalConfirmed")

    /// Posted when a tool proposal is denied by the user
    static let proposalDenied = Notification.Name("proposalDenied")
}

// MARK: - Overlay Panel Subclass

private class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        return true
    }
}
