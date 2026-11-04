// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// A single parametric EQ filter from an AutoEQ ParametricEQ profile.
struct AutoEQFilter: Codable, Sendable {
    enum FilterType: String, Codable, Sendable {
        case peaking   // PK — bell/peaking
        case lowShelf  // LS
        case highShelf // HS
        case lowPass   // LP
        case highPass  // HP
        case notch     // NO
    }

    let type: FilterType
    let frequency: Float  // Hz
    let gain: Float       // dB (meaningful for PK, LS, HS)
    let q: Float          // Q factor
    let bypass: Bool      // true when the source line says OFF
}

/// A complete AutoEQ profile parsed from a ParametricEQ.txt file.
struct AutoEQProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let preampGain: Float        // dB — usually negative, prevents clipping
    let filters: [AutoEQFilter]

    init(id: UUID = UUID(), name: String, preampGain: Float, filters: [AutoEQFilter]) {
        self.id = id
        self.name = name
        self.preampGain = preampGain
        self.filters = filters
    }
}

// MARK: - AutoEQ ParametricEQ parser

extension AutoEQProfile {
    /// Parses an AutoEQ ParametricEQ.txt file into an AutoEQProfile.
    ///
    /// Expected format:
    /// ```
    /// Preamp: -6.5 dB
    /// Filter 1: ON PK Fc 32 Hz Gain 4.0 dB Q 1.410
    /// Filter 2: ON LS Fc 105 Hz Gain -2.5 dB Q 0.700
    /// ```
    static func parse(text: String, name: String) throws -> AutoEQProfile {
        var preampGain: Float = 0
        var filters: [AutoEQFilter] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let lower = trimmed.lowercased()
            if lower.hasPrefix("preamp:") {
                preampGain = try parsePreamp(trimmed)
            } else if lower.hasPrefix("filter") {
                if let filter = try parseFilter(trimmed) {
                    filters.append(filter)
                }
            }
        }

        guard !filters.isEmpty else { throw AutoEQParseError.noFiltersFound }
        return AutoEQProfile(name: name, preampGain: preampGain, filters: filters)
    }

    // MARK: - Private line parsers

    private static func parsePreamp(_ line: String) throws -> Float {
        // "Preamp: -6.5 dB"
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2, let value = Float(parts[1]) else {
            throw AutoEQParseError.invalidPreamp(line)
        }
        return value
    }

    private static func parseFilter(_ line: String) throws -> AutoEQFilter? {
        // "Filter 1: ON PK Fc 32 Hz Gain 4.0 dB Q 1.410"
        // "Filter 7: ON LP Fc 20000 Hz"  — gain/Q optional for LP/HP
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 4 else { return nil }

        let bypass = parts[2].uppercased() == "OFF"

        let type: AutoEQFilter.FilterType
        switch parts[3].uppercased() {
        case "PK", "PEQ":           type = .peaking
        case "LS", "LSC", "LSQ":    type = .lowShelf
        case "HS", "HSC", "HSQ":    type = .highShelf
        case "LP", "LPQ":           type = .lowPass
        case "HP", "HPQ":           type = .highPass
        case "NO", "NOTCH":         type = .notch
        default:                    return nil
        }

        // Keyword-based: scan for "fc", "gain", "q" labels regardless of position.
        let lower = parts.map { $0.lowercased() }
        func tokenAfter(_ key: String) -> String? {
            guard let i = lower.firstIndex(of: key), i + 1 < parts.count else { return nil }
            return parts[i + 1]
        }

        guard let freq = tokenAfter("fc").flatMap(Float.init) else { return nil }
        let gain = tokenAfter("gain").flatMap(Float.init) ?? 0

        // Q: prefer explicit "Q" label; fall back to "BW Oct" (Equalizer APO format); then Butterworth.
        let q: Float
        if let qVal = tokenAfter("q").flatMap(Float.init) {
            q = max(0.001, qVal)
        } else if let bwIdx = lower.firstIndex(of: "bw"),
                  bwIdx + 2 < parts.count,
                  lower[bwIdx + 1] == "oct",
                  let bw = Double(parts[bwIdx + 2]), bw > 0 {
            // BW Oct → Q: Q = sqrt(2^N) / (2^N - 1)
            let pow2 = pow(2.0, bw)
            q = max(0.001, Float(pow2.squareRoot() / (pow2 - 1)))
        } else {
            q = 0.707  // Butterworth default when Q absent (e.g. bare LP/HP lines)
        }

        return AutoEQFilter(type: type, frequency: freq, gain: gain, q: q, bypass: bypass)
    }
}

// MARK: - Parse errors

enum AutoEQParseError: LocalizedError {
    case noFiltersFound
    case invalidPreamp(String)
    case invalidFilter(String)

    var errorDescription: String? {
        switch self {
        case .noFiltersFound:        "No EQ filters found in this file. Make sure you're importing a ParametricEQ.txt file."
        case .invalidPreamp(let l): "Could not parse preamp line: \(l)"
        case .invalidFilter(let l): "Could not parse filter line: \(l)"
        }
    }
}
