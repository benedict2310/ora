# Hotkey Overlay Investigation & Fix Report

## Issue
When pressing the global hotkey, the overlay window was not appearing. This was a regression after implementing `A.04-HOTKEY-WIRING.md`.

## Root Cause Analysis
1.  **Style Mask Mismatch**: The `OverlayWindowController` was using `[.nonactivatingPanel, .borderless]`. The `.nonactivatingPanel` mask prevents the window from becoming the key window and activating the application. Since the app runs in `.accessory` mode (menu bar only), `makeKeyAndOrderFront` might fail to bring the window to the front or make it visible if the app isn't active and the window is non-activating.
2.  **Animation Logic**: The `show()` method called `makeKeyAndOrderFront(nil)` and *immediately* set `alphaValue = 0` before animating to 1. While this might work, the correct pattern (as per `HOTKEY_OVERLAY_INVESTIGATION.md`) is to set `alphaValue = 0` *before* ordering the window to the front to ensure a smooth transition and avoid potential state issues.
3.  **Key Window Capability**: `NSPanel` (and `NSWindow`) with `.borderless` style mask returns `false` for `canBecomeKeyWindow` by default. This prevents the window from accepting keyboard events (shortcuts), which are needed for the overlay's "Cancel" button and potentially other interactions.

## Fix Implementation
1.  **Removed `.nonactivatingPanel`**: Changed the style mask to `[.borderless]` to allow standard window behavior regarding activation.
2.  **Corrected Animation Order**: Updated `show()` to set `alphaValue = 0` *before* calling `makeKeyAndOrderFront`.
3.  **Subclassed NSPanel**: Created a private `OverlayPanel` subclass that overrides `canBecomeKeyWindow` to return `true`.
4.  **Focus Settings**: Set `becomesKeyOnlyIfNeeded = false` to ensure the window becomes key immediately when shown.
5.  **App Activation**: Added `NSApp.activate(ignoringOtherApps: true)` to `show()` to ensure the application (which runs in accessory mode) can properly present the window and receive input.

## Files Modified
- `Ora/Overlay/OverlayWindowController.swift`

## Verification
- The overlay should now appear when the hotkey is pressed.
- The window should animate in smoothly.
- The window should be able to accept keyboard focus (e.g., for Escape key to close).
- The application should activate (come to front) when the overlay is shown.
