//
//  ScriptTrustRecordModel.swift
//  Ora
//
//  Persisted trust state for skill scripts.
//

import Foundation
import SwiftData

@Model
final class ScriptTrustRecordModel {

    @Attribute(.unique) var skillID: String
    var trustedAt: Date
    var scriptHashesData: Data
    var acknowledgedNetworkHashesData: Data

    init(
        skillID: String,
        trustedAt: Date = Date(),
        scriptHashesData: Data,
        acknowledgedNetworkHashesData: Data
    ) {
        self.skillID = skillID
        self.trustedAt = trustedAt
        self.scriptHashesData = scriptHashesData
        self.acknowledgedNetworkHashesData = acknowledgedNetworkHashesData
    }

    var scriptHashes: [String: String] {
        get {
            (try? JSONDecoder().decode([String: String].self, from: self.scriptHashesData)) ?? [:]
        }
        set {
            self.scriptHashesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var acknowledgedNetworkHashes: Set<String> {
        get {
            let decoded = (try? JSONDecoder().decode([String].self, from: self.acknowledgedNetworkHashesData)) ?? []
            return Set(decoded)
        }
        set {
            self.acknowledgedNetworkHashesData = (try? JSONEncoder().encode(Array(newValue).sorted())) ?? Data()
        }
    }
}
