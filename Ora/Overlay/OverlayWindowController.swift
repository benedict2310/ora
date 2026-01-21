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
    private var currentSessionID: UUID = UUID()

    /// Whether Reduce Motion is enabled (cached for animation decisions)
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var escapeMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var permissionPromptEndObserver: NSObjectProtocol?
    private var externalFocusEndObserver: NSObjectProtocol?

    /// Default cancel action (override in tests)
    var cancelHandler: (() -> Void) = {
        SimplePipelineController.shared.cancel()
    }

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

    /// Invalidate window shadow to clear glass rendering artifacts.
    /// Call this after layout changes or content updates that may leave visual artifacts.
    func invalidateShadow() {
        self.panel?.invalidateShadow()
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

        // Invalidate any pending hide operations
        self.currentSessionID = UUID()

        // Position the panel (at final position, animation offsets handled separately)
        self.positionPanel()

        // Invalidate shadow to clear any stale rendering artifacts from previous sessions
        panel.invalidateShadow()

        // Animate in with slide + fade (respecting Reduce Motion)
        if self.reduceMotion {
            // No animation - show immediately
            panel.alphaValue = 1
        } else {
            // Start slightly above final position and faded out
            let finalOrigin = panel.frame.origin
            let startOrigin = NSPoint(x: finalOrigin.x, y: finalOrigin.y + OverlayLayout.showHideSlideDistance)
            panel.setFrameOrigin(startOrigin)
            panel.alphaValue = 0

            // Animate to final position
            NSAnimationContext.runAnimationGroup { context in
                context.duration = OverlayLayout.showAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(finalOrigin)
                panel.animator().alphaValue = 1
            }
        }

        // Use orderFrontRegardless for more aggressive window ordering
        // This helps when coming back from system dialogs (e.g., permission prompts)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        // Ensure app is active to receive input (required for accessory apps)
        // Use the newer API which works better with accessory apps
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])

        // Add dismiss monitors
        self.addDismissMonitors()

        self.logger.debug("Overlay shown")
    }

    /// Hide the overlay window
    func hide(animated: Bool = true) {
        guard let panel = self.panel else { return }

        // Remove dismiss monitors
        self.removeDismissMonitors()
        
        let hideSessionID = self.currentSessionID

        if animated && !self.reduceMotion {
            // Animate out with slide up + fade
            let currentOrigin = panel.frame.origin
            let targetOrigin = NSPoint(x: currentOrigin.x, y: currentOrigin.y + OverlayLayout.showHideSlideDistance)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = OverlayLayout.hideAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrameOrigin(targetOrigin)
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor [weak self] in
                    // Only hide if we haven't started a new show session
                    guard let self = self, self.currentSessionID == hideSessionID else { return }
                    panel.orderOut(nil)
                    self.viewModel.reset()
                }
            }
        } else {
            // No animation - hide immediately
            guard self.currentSessionID == hideSessionID else { return }
            panel.orderOut(nil)
            self.viewModel.reset()
        }

        self.logger.debug("Overlay hidden")
    }

    // MARK: - Private

    private func createPanel() {
        let panelSize = NSSize(width: OverlayLayout.panelWidth, height: OverlayLayout.panelHeight)

        let contentView = OverlayView()
            .environmentObject(self.viewModel)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(panelSize)

        // Create floating panel
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
        let y = screenFrame.maxY - panelSize.height - OverlayLayout.topMargin

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Dismiss Monitors

    private func addDismissMonitors() {
        guard self.escapeMonitor == nil else { return }

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

        self.appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDeactivated()
        }

        self.appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppActivated()
        }

        self.permissionPromptEndObserver = NotificationCenter.default.addObserver(
            forName: .permissionPromptDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePermissionPromptEnded()
        }

        self.externalFocusEndObserver = NotificationCenter.default.addObserver(
            forName: .externalFocusOperationDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleExternalFocusEnded()
        }
    }

    private func removeDismissMonitors() {
        if let monitor = self.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            self.escapeMonitor = nil
        }

        if let observer = self.appDeactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            self.appDeactivationObserver = nil
        }

        if let observer = self.appActivationObserver {
            NotificationCenter.default.removeObserver(observer)
            self.appActivationObserver = nil
        }

        if let observer = self.permissionPromptEndObserver {
            NotificationCenter.default.removeObserver(observer)
            self.permissionPromptEndObserver = nil
        }

        if let observer = self.externalFocusEndObserver {
            NotificationCenter.default.removeObserver(observer)
            self.externalFocusEndObserver = nil
        }
    }

    private func handleAppDeactivated() {
        let isVisible = self.isVisible
        let isPromptActive = PermissionPromptTracker.shared.isPromptActive
        let isExternalOp = ExternalFocusTracker.shared.isExternalOperationActive

        guard isVisible else { return }
        guard !isPromptActive else {
            self.logger.debug("App deactivated during permission prompt; keeping overlay")
            return
        }
        guard !isExternalOp else {
            self.logger.debug("App deactivated during external focus operation; keeping overlay")
            return
        }

        self.logger.info("App deactivated; cancelling session")
        self.cancelHandler()
    }

    // MARK: - Focus Recovery

    private func handlePermissionPromptEnded() {
        guard SimplePipelineController.shared.isSessionActive else { return }
        self.logger.debug("Permission prompt ended; restoring overlay focus")

        // Delay restoration to let the window system settle after the permission dialog dismisses.
        // Without this delay, the window ordering commands execute before the system has finished
        // cleaning up the permission dialog, causing our panel to appear "visible" but actually
        // hidden behind other windows (BUG-006).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            guard SimplePipelineController.shared.isSessionActive else { return }
            self.restoreAfterExternalDialog()
        }
    }

    /// Restore the overlay after an external dialog (like permission prompts) has dismissed.
    /// This uses more aggressive window ordering to ensure the panel becomes visible.
    private func restoreAfterExternalDialog() {
        guard let panel = self.panel else {
            self.show()
            return
        }

        // First, ensure the app is active
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])

        // Bump window level temporarily to get above any lingering system dialogs.
        // This is necessary because after a system permission dialog dismisses,
        // the window ordering state may not have fully settled.
        let originalLevel = panel.level
        panel.level = .popUpMenu

        // Force the panel to front
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        // Restore original level after a brief moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            panel.level = originalLevel
        }

        self.logger.debug("Overlay restored after external dialog")
    }

    private func handleAppActivated() {
        // When app becomes active again, restore overlay if session is still active
        // This handles cases where permission dialogs or external app focus
        // didn't trigger the specific end notifications
        guard SimplePipelineController.shared.isSessionActive else { return }

        // Check if overlay needs restoration (hidden or nearly invisible)
        let needsRestoration = !self.isVisible || (self.panel?.alphaValue ?? 0) < 0.5
        guard needsRestoration else { return }

        self.logger.debug("App activated with active session; restoring overlay")
        self.restoreAfterExternalDialog()
    }

    private func handleExternalFocusEnded() {
        // External focus operation completed - no need to restore focus
        // since user intentionally opened another app/folder
        self.logger.debug("External focus operation ended")
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
