//
//  AppIcon.swift
//  Ora
//
//  Helper to load app icon from asset catalog
//

import AppKit

enum AppIcon {
    /// The app icon loaded from the asset catalog or bundle
    static var image: NSImage {
        // Try to load from asset catalog (preferred - works with Assets.xcassets)
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }
        // Try to load from bundle's icon file (legacy .icns approach)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }
        // Fallback to application icon image
        return NSApp.applicationIconImage
    }
}
