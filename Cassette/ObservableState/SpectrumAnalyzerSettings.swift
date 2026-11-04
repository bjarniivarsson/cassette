// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import SwiftUI

/// Per-channel color pair for the spectrum analyzer curve.
/// Left/right colors control the stroke and (at reduced opacity) the gradient fill.
struct SpectrumTheme: Sendable, Equatable {
    let leftColor: Color
    let rightColor: Color
}

/// Named, predefined spectrum analyzer themes.
enum SpectrumThemeOption: String, CaseIterable, Identifiable, Sendable {
    case white  = "white"
    case blueRed = "blueRed"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white:   "White"
        case .blueRed: "Blue / Red"
        }
    }

    var theme: SpectrumTheme {
        switch self {
        case .white:   SpectrumTheme(leftColor: .white, rightColor: .white)
        case .blueRed: SpectrumTheme(leftColor: .blue, rightColor: .red)
        }
    }
}

/// Detail level for the spectrum analyzer curve (number of frequency bins).
enum SpectrumBinDetail: Int, CaseIterable, Identifiable, Sendable {
    case low    = 10
    case medium = 20
    case high   = 40

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low:    "Low"
        case .medium: "Medium"
        case .high:   "High"
        }
    }
}

/// Sendable snapshot passed to SpectrumAnalyzerService across actor boundaries.
nonisolated struct SpectrumAnalyzerConfig: Sendable, Equatable {
    let isEnabled: Bool
    let binCount: Int          // 10, 20, or 40
    let dbFloor: Float         // -40 to -80 — lower = more sensitive
    let attackCoefficient: Float  // 0.3 (smooth) to 1.0 (reactive)
    let showStereo: Bool
    let themeOption: SpectrumThemeOption

    static let `default` = SpectrumAnalyzerConfig(
        isEnabled: true,
        binCount: 20,
        dbFloor: -60,
        attackCoefficient: 0.8,
        showStereo: true,
        themeOption: .white
    )
}

/// User-configurable spectrum analyzer preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes a setting.
@Observable
@MainActor
final class SpectrumAnalyzerSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private var _isEnabled: Bool
    @ObservationIgnored private var _binDetail: SpectrumBinDetail
    @ObservationIgnored private var _sensitivity: Double   // the actual dB floor value (-40 to -80)
    @ObservationIgnored private var _responsiveness: Double  // attack coefficient (0.3 to 1.0)
    @ObservationIgnored private var _showStereo: Bool
    @ObservationIgnored private var _themeOption: SpectrumThemeOption

    // MARK: - Visible properties (manual observation hooks)

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

    var binDetail: SpectrumBinDetail {
        get {
            access(keyPath: \.binDetail)
            return _binDetail
        }
        set {
            withMutation(keyPath: \.binDetail) { _binDetail = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.binDetailKey)
        }
    }

    /// dB floor: -80 (maximum sensitivity) to -40 (minimum sensitivity). Default -60.
    var sensitivity: Double {
        get {
            access(keyPath: \.sensitivity)
            return _sensitivity
        }
        set {
            let clamped = max(Self.minSensitivity, min(Self.maxSensitivity, newValue))
            withMutation(keyPath: \.sensitivity) { _sensitivity = clamped }
            UserDefaults.standard.set(clamped, forKey: Self.sensitivityKey)
        }
    }

    /// Attack weight on each new FFT frame: 0.3 (smooth) to 1.0 (instant). Default 0.8.
    var responsiveness: Double {
        get {
            access(keyPath: \.responsiveness)
            return _responsiveness
        }
        set {
            let clamped = max(Self.minResponsiveness, min(Self.maxResponsiveness, newValue))
            withMutation(keyPath: \.responsiveness) { _responsiveness = clamped }
            UserDefaults.standard.set(clamped, forKey: Self.responsivenessKey)
        }
    }

    var showStereo: Bool {
        get {
            access(keyPath: \.showStereo)
            return _showStereo
        }
        set {
            withMutation(keyPath: \.showStereo) { _showStereo = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.showStereoKey)
        }
    }

    var themeOption: SpectrumThemeOption {
        get {
            access(keyPath: \.themeOption)
            return _themeOption
        }
        set {
            withMutation(keyPath: \.themeOption) { _themeOption = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.themeOptionKey)
        }
    }

    // MARK: - Defaults, bounds & keys

    static let defaultIsEnabled: Bool = true
    static let defaultBinDetail: SpectrumBinDetail = .medium
    static let defaultSensitivity: Double = -60
    static let defaultResponsiveness: Double = 0.8
    static let defaultShowStereo: Bool = true
    static let defaultThemeOption: SpectrumThemeOption = .white

    // Sensitivity stores the dB floor value; more negative = more sensitive.
    // Slider goes from minSensitivity (most sensitive) to maxSensitivity (least sensitive).
    static let minSensitivity: Double = -80
    static let maxSensitivity: Double = -40
    static let minResponsiveness: Double = 0.3
    static let maxResponsiveness: Double = 1.0

    private static let isEnabledKey       = "cassette.spectrum.isEnabled"
    private static let binDetailKey       = "cassette.spectrum.binDetail"
    private static let sensitivityKey     = "cassette.spectrum.sensitivity"
    private static let responsivenessKey  = "cassette.spectrum.responsiveness"
    private static let showStereoKey      = "cassette.spectrum.showStereo"
    private static let themeOptionKey     = "cassette.spectrum.themeOption"

    // MARK: - Derived

    var config: SpectrumAnalyzerConfig {
        SpectrumAnalyzerConfig(
            isEnabled: _isEnabled,
            binCount: _binDetail.rawValue,
            dbFloor: Float(_sensitivity),
            attackCoefficient: Float(_responsiveness),
            showStereo: _showStereo,
            themeOption: _themeOption
        )
    }

    // MARK: - Init

    init() {
        if UserDefaults.standard.object(forKey: Self.isEnabledKey) != nil {
            _isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledKey)
        } else {
            _isEnabled = Self.defaultIsEnabled
        }

        let binRaw = UserDefaults.standard.integer(forKey: Self.binDetailKey)
        _binDetail = SpectrumBinDetail(rawValue: binRaw) ?? Self.defaultBinDetail

        if UserDefaults.standard.object(forKey: Self.sensitivityKey) != nil {
            let stored = UserDefaults.standard.double(forKey: Self.sensitivityKey)
            _sensitivity = max(Self.minSensitivity, min(Self.maxSensitivity, stored))
        } else {
            _sensitivity = Self.defaultSensitivity
        }

        if UserDefaults.standard.object(forKey: Self.responsivenessKey) != nil {
            let stored = UserDefaults.standard.double(forKey: Self.responsivenessKey)
            _responsiveness = max(Self.minResponsiveness, min(Self.maxResponsiveness, stored))
        } else {
            _responsiveness = Self.defaultResponsiveness
        }

        if UserDefaults.standard.object(forKey: Self.showStereoKey) != nil {
            _showStereo = UserDefaults.standard.bool(forKey: Self.showStereoKey)
        } else {
            _showStereo = Self.defaultShowStereo
        }

        let themeRaw = UserDefaults.standard.string(forKey: Self.themeOptionKey) ?? ""
        _themeOption = SpectrumThemeOption(rawValue: themeRaw) ?? Self.defaultThemeOption
    }
}
