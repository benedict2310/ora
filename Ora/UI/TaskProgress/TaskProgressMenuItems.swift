//
//  TaskProgressMenuItems.swift
//  Ora
//
//  Helpers for rendering task progress in the status bar menu.
//

import AppKit

enum TaskProgressMenuItems {

    static let sectionTitle = "Background Tasks"

    static func makeSection(
        tasks: [TaskProgressItem],
        target: AnyObject?,
        cancelAction: Selector
    ) -> [NSMenuItem] {
        guard !tasks.isEmpty else {
            return []
        }

        var items: [NSMenuItem] = []

        let header = NSMenuItem(title: Self.sectionTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)

        for task in tasks {
            let statusItem = NSMenuItem(title: task.menuTitle, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            statusItem.toolTip = task.detail
            items.append(statusItem)

            let cancelItem = NSMenuItem(
                title: "Cancel \(task.label)",
                action: cancelAction,
                keyEquivalent: ""
            )
            cancelItem.target = target
            cancelItem.indentationLevel = 1
            cancelItem.representedObject = task.id as NSUUID
            items.append(cancelItem)
        }
        return items
    }
}
