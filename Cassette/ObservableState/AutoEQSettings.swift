// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// User-configurable AutoEQ preferences persisted in UserDefaults.
@Observable
@MainActor
final class AutoEQSettings {
    // MARK: - Storage

    @ObservationIgnored private var _isEnabled: Bool
    @ObservationIgnored private var _selectedProfileID: UUID?

    // MARK: - Observable properties

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return _isEnabled
        }
        set {
            withMutation(keyPath: \.isEnabled) { _isEnabled = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.isEnabledKey)
        }
    }

    var selectedProfileID: UUID? {
        get {
            access(keyPath: \.selectedProfileID)
            return _selectedProfileID
        }
        set {
            withMutation(keyPath: \.selectedProfileID) { _selectedProfileID = newValue }
            if let id = newValue {
                UserDefaults.standard.set(id.uuidString, forKey: Self.selectedProfileIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedProfileIDKey)
            }
        }
    }

    // MARK: - Keys & defaults

    static let defaultIsEnabled: Bool = true

    private static let isEnabledKey        = "cassette.autoEQ.isEnabled"
    private static let selectedProfileIDKey = "cassette.autoEQ.selectedProfileID"

    // MARK: - Init

    init() {
        if UserDefaults.standard.object(forKey: Self.isEnabledKey) != nil {
            _isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledKey)
        } else {
            _isEnabled = Self.defaultIsEnabled
        }

        if let raw = UserDefaults.standard.string(forKey: Self.selectedProfileIDKey) {
            _selectedProfileID = UUID(uuidString: raw)
        } else {
            _selectedProfileID = nil
        }
    }
}
