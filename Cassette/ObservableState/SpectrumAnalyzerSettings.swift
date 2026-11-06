// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import SwiftUI

/// Which visualizer style to render in the full-screen player.
enum SpectrumVisualizerType: String, CaseIterable, Identifiable, Sendable {
    case lines       = "lines"
    case bars        = "bars"
    case spectrogram = "spectrogram"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lines:       "Lines"
        case .bars:        "Bars"
        case .spectrogram: "Spectrogram"
        }
    }
}

/// FFT window size controlling the frequency-vs-time resolution tradeoff.
/// Larger → finer frequency bins, more latency; smaller → coarser bins, more responsive.
enum SpectrumFFTSize: Int, CaseIterable, Identifiable, Sendable {
    case n1024 = 1024
    case n2048 = 2048
    case n4096 = 4096
    case n8192 = 8192

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .n1024: "1024"
        case .n2048: "2048"
        case .n4096: "4096"
        case .n8192: "8192"
        }
    }

    var log2n: Int {
        switch self {
        case .n1024: 10
        case .n2048: 11
        case .n4096: 12
        case .n8192: 13
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
    let useReassignment: Bool  // time-frequency reassignment for sharper spectrogram
    let fftSize: SpectrumFFTSize
    let targetFPS: Double      // publish rate cap: 30 for bars/lines, 60 for spectrogram

    static let `default` = SpectrumAnalyzerConfig(
        isEnabled: true,
        binCount: 20,
        dbFloor: -60,
        attackCoefficient: 0.8,
        showStereo: true,
        useReassignment: false,
        fftSize: .n2048,
        targetFPS: 30
    )
}

/// User-configurable spectrum analyzer preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes a setting.
@Observable
@MainActor
final class SpectrumAnalyzerSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private var _isEnabled: Bool
    @ObservationIgnored private var _visualizerType: SpectrumVisualizerType
    @ObservationIgnored private var _binDetail: SpectrumBinDetail
    @ObservationIgnored private var _sensitivity: Double   // the actual dB floor value (-40 to -80)
    @ObservationIgnored private var _responsiveness: Double  // attack coefficient (0.3 to 1.0)
    @ObservationIgnored private var _showStereo: Bool
    @ObservationIgnored private var _useReassignment: Bool

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

    var visualizerType: SpectrumVisualizerType {
        get {
            access(keyPath: \.visualizerType)
            return _visualizerType
        }
        set {
            withMutation(keyPath: \.visualizerType) { _visualizerType = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.visualizerTypeKey)
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

    var useReassignment: Bool {
        get {
            access(keyPath: \.useReassignment)
            return _useReassignment
        }
        set {
            withMutation(keyPath: \.useReassignment) { _useReassignment = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.useReassignmentKey)
        }
    }

    // MARK: - Defaults, bounds & keys

    static let defaultIsEnabled: Bool = true
    static let defaultVisualizerType: SpectrumVisualizerType = .lines
    static let defaultBinDetail: SpectrumBinDetail = .medium
    static let defaultSensitivity: Double = -60
    static let defaultResponsiveness: Double = 0.8
    static let defaultShowStereo: Bool = true
    static let defaultUseReassignment: Bool = false

    // Sensitivity stores the dB floor value; more negative = more sensitive.
    // Slider goes from minSensitivity (most sensitive) to maxSensitivity (least sensitive).
    static let minSensitivity: Double = -80
    static let maxSensitivity: Double = -40
    static let minResponsiveness: Double = 0.3
    static let maxResponsiveness: Double = 1.0

    private static let isEnabledKey        = "cassette.spectrum.isEnabled"
    private static let visualizerTypeKey   = "cassette.spectrum.visualizerType"
    private static let binDetailKey        = "cassette.spectrum.binDetail"
    private static let sensitivityKey      = "cassette.spectrum.sensitivity"
    private static let responsivenessKey   = "cassette.spectrum.responsiveness"
    private static let showStereoKey       = "cassette.spectrum.showStereo"
    private static let useReassignmentKey  = "cassette.spectrum.useReassignment"

    // MARK: - Derived

    var config: SpectrumAnalyzerConfig {
        // FFT size is determined by the visualizer: spectrogram benefits from higher
        // frequency resolution (8192); bar and line views are fine at 2048.
        let isSpectrogram = _visualizerType == .spectrogram
        return SpectrumAnalyzerConfig(
            isEnabled: _isEnabled,
            binCount: _binDetail.rawValue,
            dbFloor: Float(_sensitivity),
            attackCoefficient: Float(_responsiveness),
            showStereo: isSpectrogram || _showStereo,
            useReassignment: isSpectrogram && _useReassignment,
            fftSize: isSpectrogram ? .n8192 : .n2048,
            targetFPS: isSpectrogram ? 60 : 30
        )
    }

    // MARK: - Init

    init() {
        if UserDefaults.standard.object(forKey: Self.isEnabledKey) != nil {
            _isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledKey)
        } else {
            _isEnabled = Self.defaultIsEnabled
        }

        let typeRaw = UserDefaults.standard.string(forKey: Self.visualizerTypeKey) ?? ""
        _visualizerType = SpectrumVisualizerType(rawValue: typeRaw) ?? Self.defaultVisualizerType

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

        if UserDefaults.standard.object(forKey: Self.useReassignmentKey) != nil {
            _useReassignment = UserDefaults.standard.bool(forKey: Self.useReassignmentKey)
        } else {
            _useReassignment = Self.defaultUseReassignment
        }
    }
}
