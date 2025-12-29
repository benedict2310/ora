//
//  ASRNotifications.swift
//  Ora
//
//  Notification name constants for Parakeet ASR state changes
//

import Foundation

extension Notification.Name {
    /// Posted when Parakeet download state changes
    /// - Object: ParakeetModelDownloader.State
    static let parakeetDownloadStateDidChange = Notification.Name("parakeetDownloadStateDidChange")

    /// Posted when Parakeet engine state changes
    /// - Object: ParakeetBootstrap.EngineState
    static let parakeetEngineStateDidChange = Notification.Name("parakeetEngineStateDidChange")
}
