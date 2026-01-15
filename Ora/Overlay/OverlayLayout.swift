//
//  OverlayLayout.swift
//  Ora
//
//  Shared spacing and padding constants for the overlay UI
//

import Foundation

/// Shared layout constants for the overlay UI
///
/// These constants ensure consistent spacing across all overlay components.
///
/// ## Unified Glass Architecture
///
/// The chat scroll view uses a **single unified glass sampling region** rather than
/// per-bubble glass effects. This eliminates black outline artifacts between bubbles
/// that occur when "glass samples glass" (per Apple's Liquid Glass guidance).
///
/// **Architecture:**
/// ```
/// GlassEffectContainer
/// ├── VoiceInputControlView     → .glassEffect() (separate for morphing)
/// └── ScrollView                → .glassEffect() (ONE unified region)
///     ├── ChatBubbleView        → .background(tintedShape) (no glass)
///     ├── ToolStateView         → .background(tintedShape) (no glass)
///     └── FollowUpPromptView    → .background(tintedShape) (no glass)
/// ```
///
/// Per-bubble styling is achieved via translucent background fills on top of the
/// unified blur, not via individual `.glassEffect()` calls.
enum OverlayLayout {
    // MARK: - Container Spacing

    /// Spacing for the outer `GlassEffectContainer`
    ///
    /// Controls separation between VoiceInputControlView and the chat scroll view.
    static let containerSpacing: CGFloat = 4

    // MARK: - Row Spacing

    /// Vertical spacing between rows in the main chat scroll view (LazyVStack)
    ///
    /// This spacing separates consecutive messages, tool blocks, and follow-up prompts.
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
