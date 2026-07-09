# Hotkey Overlay Investigation & Fix Report

## Issue
When pressing the global hotkey, the overlay window was not appearing. This was a regression after implementing `A.04-HOTKEY-WIRING.md`.

## Root Cause Analysis

### Original Issues (Dec 30)
1.  **Style Mask Mismatch**: The `OverlayWindowController` was using `[.nonactivatingPanel, .borderless]`. The `.nonactivatingPanel` mask prevents the window from becoming the key window and activating the application. Since the app runs in `.accessory` mode (menu bar only), `makeKeyAndOrderFront` might fail to bring the window to the front or make it visible if the app isn't active and the window is non-activating.
2.  **Animation Logic**: The `show()` method called `makeKeyAndOrderFront(nil)` and *immediately* set `alphaValue = 0` before animating to 1. While this might work, the correct pattern (as per `HOTKEY_OVERLAY_INVESTIGATION.md`) is to set `alphaValue = 0` *before* ordering the window to the front to ensure a smooth transition and avoid potential state issues.
3.  **Key Window Capability**: `NSPanel` (and `NSWindow`) with `.borderless` style mask returns `false` for `canBecomeKeyWindow` by default. This prevents the window from accepting keyboard events (shortcuts), which are needed for the overlay's "Cancel" button and potentially other interactions.

### Additional Issue Found (Dec 31)
4.  **NSAnimationContext Unreliable in Release Builds**: The `NSAnimationContext.runAnimationGroup` animation was not completing in Release builds. The alpha value was being set to 0, the animation was started with `panel.animator().alphaValue = 1`, but the animation never executed - the panel remained at `alphaValue = 0` (invisible). This caused the overlay to be "shown" (visible=true, positioned correctly) but completely transparent.

## Fix Implementation
1.  **Removed `.nonactivatingPanel`**: Changed the style mask to `[.borderless]` to allow standard window behavior regarding activation.
2.  **Subclassed NSPanel**: Created a private `OverlayPanel` subclass that overrides `canBecomeKeyWindow` to return `true`.
3.  **Focus Settings**: Set `becomesKeyOnlyIfNeeded = false` to ensure the window becomes key immediately when shown.
4.  **App Activation**: Added `NSApp.activate(ignoringOtherApps: true)` to `show()` to ensure the application (which runs in accessory mode) can properly present the window and receive input.
5.  **Direct Alpha Assignment**: Replaced unreliable `NSAnimationContext.runAnimationGroup` animation with direct `panel.alphaValue = 1` assignment. This ensures the overlay is immediately visible in both Debug and Release builds.

## Files Modified
- `Ora/Overlay/OverlayWindowController.swift`

## Technical Details

### Why NSAnimationContext Failed
In Release builds with optimization enabled, the `NSAnimationContext.runAnimationGroup` closure may not execute animations as expected. The issue manifests as:
- `panel.alphaValue = 0` executes
- `makeKeyAndOrderFront(nil)` executes (window is visible but transparent)
- `NSAnimationContext.runAnimationGroup { panel.animator().alphaValue = 1 }` is called
- Animation never completes - alpha stays at 0

The fix sets `alphaValue = 1` directly after `makeKeyAndOrderFront`, bypassing the animation system entirely. If animation is desired in the future, consider using:
- `NSView.animate(withDuration:animations:)` 
- Core Animation (`CABasicAnimation`) 
- Scheduled timer-based interpolation

## Verification
- [x] The overlay appears when the hotkey is pressed
- [x] The window is visible (alpha = 1) immediately
- [x] The window can accept keyboard focus (Escape key to close)
- [x] The application activates (comes to front) when the overlay is shown
- [x] Works in both Debug and Release builds
