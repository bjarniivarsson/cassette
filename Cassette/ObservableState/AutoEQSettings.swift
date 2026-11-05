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
    @ObservationIgnored private var _deviceSpecificEnabled: Bool
    @ObservationIgnored private var _targetDeviceUID: String?
    @ObservationIgnored private var _targetDeviceName: String?

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

    /// When true, AutoEQ is only applied when the output device matches `targetDeviceUID`.
    var deviceSpecificEnabled: Bool {
        get {
            access(keyPath: \.deviceSpecificEnabled)
            return _deviceSpecificEnabled
        }
        set {
            withMutation(keyPath: \.deviceSpecificEnabled) { _deviceSpecificEnabled = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.deviceSpecificEnabledKey)
        }
    }

    /// UID of the device AutoEQ should activate for (when `deviceSpecificEnabled` is true).
    var targetDeviceUID: String? {
        get {
            access(keyPath: \.targetDeviceUID)
            return _targetDeviceUID
        }
        set {
            withMutation(keyPath: \.targetDeviceUID) { _targetDeviceUID = newValue }
            if let uid = newValue {
                UserDefaults.standard.set(uid, forKey: Self.targetDeviceUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.targetDeviceUIDKey)
            }
        }
    }

    /// Display name of the target device (stored alongside UID so the UI can show it without querying Core Audio).
    var targetDeviceName: String? {
        get {
            access(keyPath: \.targetDeviceName)
            return _targetDeviceName
        }
        set {
            withMutation(keyPath: \.targetDeviceName) { _targetDeviceName = newValue }
            if let name = newValue {
                UserDefaults.standard.set(name, forKey: Self.targetDeviceNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.targetDeviceNameKey)
            }
        }
    }

    // MARK: - Effective state

    /// Returns true when AutoEQ should actually be applied given the current output device UID.
    func isEffectivelyEnabled(currentDeviceUID: String?) -> Bool {
        guard isEnabled else { return false }
        guard deviceSpecificEnabled else { return true }
        guard let target = targetDeviceUID, let current = currentDeviceUID else { return false }
        return target == current
    }

    // MARK: - Keys & defaults

    static let defaultIsEnabled: Bool = true

    private static let isEnabledKey             = "cassette.autoEQ.isEnabled"
    private static let selectedProfileIDKey      = "cassette.autoEQ.selectedProfileID"
    private static let deviceSpecificEnabledKey  = "cassette.autoEQ.deviceSpecificEnabled"
    private static let targetDeviceUIDKey        = "cassette.autoEQ.targetDeviceUID"
    private static let targetDeviceNameKey       = "cassette.autoEQ.targetDeviceName"

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

        _deviceSpecificEnabled = UserDefaults.standard.bool(forKey: Self.deviceSpecificEnabledKey)
        _targetDeviceUID       = UserDefaults.standard.string(forKey: Self.targetDeviceUIDKey)
        _targetDeviceName      = UserDefaults.standard.string(forKey: Self.targetDeviceNameKey)
    }
}
