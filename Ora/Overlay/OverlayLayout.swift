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
    // MARK: - Panel Dimensions

    /// Width of the overlay panel
    static let panelWidth: CGFloat = 520

    /// Height of the overlay panel
    static let panelHeight: CGFloat = 400

    /// Maximum width for content inside the panel
    static let contentMaxWidth: CGFloat = 480

    /// Top margin from screen edge
    static let topMargin: CGFloat = 12

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
    /// Set to 24 for balanced visual separation without feeling sparse.
    static let rowSpacing: CGFloat = 24

    // MARK: - Bubble Sizing

    /// Maximum width for assistant/tool bubbles (wider for readability)
    static let assistantBubbleMaxWidth: CGFloat = 380

    /// Maximum width for user bubbles (tighter, right-aligned)
    static let userBubbleMaxWidth: CGFloat = 320

    /// Inset from edge for bubble alignment
    static let bubbleInset: CGFloat = 20

    // MARK: - Bubble Padding

    /// Horizontal padding inside chat bubbles and tool state views
    static let bubblePaddingHorizontal: CGFloat = 16

    /// Vertical padding inside chat bubbles and tool state views
    static let bubblePaddingVertical: CGFloat = 12

    // MARK: - Content Spacing

    /// Spacing between elements inside chat bubbles (e.g., state row and text)
    static let bubbleContentSpacing: CGFloat = 6

    /// Spacing inside tool state views (between header, summary, details, buttons)
    static let toolContentSpacing: CGFloat = 10

    // MARK: - Voice Input

    /// Vertical padding below voice input control
    static let voiceInputBottomPadding: CGFloat = 6

    // MARK: - Animation

    /// Slide distance for show/hide animation
    static let showHideSlideDistance: CGFloat = 10

    /// Duration for show animation
    static let showAnimationDuration: TimeInterval = 0.25

    /// Duration for hide animation
    static let hideAnimationDuration: TimeInterval = 0.15

    // MARK: - Skills Hint

    static func skillsHintText(for skills: [SkillMetadata]) -> String? {
        guard !skills.isEmpty else {
            return nil
        }

        let names = skills.map(\.name).joined(separator: ", ")
        let activationName = skills[0].name
        return "Available skills: \(names) — say 'use \(activationName) skill' to activate"
    }
}
