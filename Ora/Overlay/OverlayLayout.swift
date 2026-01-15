//
//  OverlayLayout.swift
//  Ora
//
//  Shared spacing and padding constants for the overlay UI
//

import Foundation

/// Shared layout constants for the overlay UI
///
/// These constants ensure consistent spacing across all overlay components
/// and prevent Liquid Glass blending artifacts by maintaining proper spacing relationships.
///
/// **Critical constraint:** `containerSpacing` must be less than `rowSpacing` to prevent
/// glass shapes from blending at rest (per Apple's Liquid Glass guidance).
enum OverlayLayout {
    // MARK: - Container Spacing

    /// Spacing for the outer `GlassEffectContainer`
    ///
    /// Must be **less than** `rowSpacing` to prevent glass shapes from blending at rest.
    /// This spacing controls when adjacent glass effects merge during transitions.
    /// Reduced to minimize glass sampling interference between separate bubbles.
    static let containerSpacing: CGFloat = 4

    // MARK: - Row Spacing

    /// Vertical spacing between rows in the main chat scroll view (LazyVStack)
    ///
    /// This spacing separates consecutive messages, tool blocks, and follow-up prompts.
    /// Must be **greater than** `containerSpacing` to prevent glass blending at rest.
    static let rowSpacing: CGFloat = 20

    // MARK: - Bubble Padding

    /// Horizontal padding inside chat bubbles and tool state views
    static let bubblePaddingHorizontal: CGFloat = 16

    /// Vertical padding inside chat bubbles and tool state views
    static let bubblePaddingVertical: CGFloat = 12

    // MARK: - Content Spacing

    /// Spacing between elements inside chat bubbles (e.g., state row and text)
    static let bubbleContentSpacing: CGFloat = 8

    /// Spacing inside tool state views (between header, summary, details, buttons)
    static let toolContentSpacing: CGFloat = 12
}
