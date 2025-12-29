//
//  AppIcon.swift
//  Ora
//
//  Helper to load app icon for display in UI (About, Welcome screens)
//

import AppKit

enum AppIcon {
    /// The app icon loaded from the asset catalog
    /// For macOS apps, we load a specific size from the appiconset
    static var image: NSImage {
        // Load the 512x512 icon directly from the asset catalog
        // Note: "AppIcon" as NSImage name doesn't work for appiconset,
        // we need to load from the compiled Assets.car or use the bundle icon
        if let icon = NSApp.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        
        // Fallback: try to load from bundle's icon file
        if let iconName = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String,
           let iconURL = Bundle.main.url(forResource: iconName, withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }
        
        // Final fallback: generic app icon
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}
