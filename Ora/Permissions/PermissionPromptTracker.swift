//
//  PermissionPromptTracker.swift
//  Ora
//
//  Tracks active permission prompts to coordinate overlay focus recovery.
//

import Foundation
import os

extension Notification.Name {
    static let permissionPromptDidBegin = Notification.Name("permissionPromptDidBegin")
    static let permissionPromptDidEnd = Notification.Name("permissionPromptDidEnd")
}

@MainActor
final class PermissionPromptTracker {

    // MARK: - Singleton

    static let shared = PermissionPromptTracker()

    // MARK: - Properties

    private let logger = Logger.ora(category: "PermissionPromptTracker")
    private var activePrompts: Set<PermissionType> = []

    var isPromptActive: Bool {
        !self.activePrompts.isEmpty
    }

    // MARK: - Init

    private init() {}

    // MARK: - Tracking

    func beginPrompt(for type: PermissionType) {
        let inserted = self.activePrompts.insert(type).inserted
        if inserted {
            self.logger.debug("Permission prompt began: \(type.rawValue)")
            NotificationCenter.default.post(name: .permissionPromptDidBegin, object: type)
        }
    }

    func endPrompt(for type: PermissionType) {
        let removed = self.activePrompts.remove(type) != nil
        guard removed else { return }

        self.logger.debug("Permission prompt ended: \(type.rawValue)")
        guard self.activePrompts.isEmpty else { return }
        NotificationCenter.default.post(name: .permissionPromptDidEnd, object: type)
    }
}
