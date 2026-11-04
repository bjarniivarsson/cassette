// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import AudioStreaming
import OSLog

/// Manages the AutoEQ correction node in the audio graph.
/// Profiles are stored as JSON files in the app's documents directory.
/// Start/stop is not needed — the node is a no-op when all bands are bypassed.
actor AutoEQService {
    // 15 bands covers all practical AutoEQ ParametricEQ profiles (typically 5–15 filters).
    private static let maxBands = 15

    private let eqNode = AVAudioUnitEQ(numberOfBands: maxBands)
    private var isAttached = false
    private let profilesDirectory: URL
    private(set) var profiles: [AutoEQProfile] = []

    init(profilesDirectory: URL) {
        self.profilesDirectory = profilesDirectory
    }

    // MARK: - Setup

    func attach(to player: AudioPlayer) {
        guard !isAttached else { return }
        player.attach(node: eqNode)
        isAttached = true
        bypassAll()
    }

    func loadProfiles() {
        do {
            try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
            let urls = (try FileManager.default.contentsOfDirectory(
                at: profilesDirectory,
                includingPropertiesForKeys: nil
            )).filter { $0.pathExtension == "json" }

            profiles = try urls.compactMap { url in
                try JSONDecoder().decode(AutoEQProfile.self, from: Data(contentsOf: url))
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            Logger.player.error("[AutoEQ] Failed to load profiles: \(error)")
        }
    }

    // MARK: - Import / Delete

    func importProfile(from url: URL, name: String) throws -> AutoEQProfile {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let text = try String(contentsOf: url, encoding: .utf8)
        let profile = try AutoEQProfile.parse(text: text, name: name)

        let dest = profilesDirectory.appendingPathComponent("\(profile.id.uuidString).json")
        try JSONEncoder().encode(profile).write(to: dest, options: .atomic)

        profiles.append(profile)
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return profile
    }

    func deleteProfile(id: UUID) throws {
        let url = profilesDirectory.appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.removeItem(at: url)
        profiles.removeAll { $0.id == id }
    }

    // MARK: - Apply

    /// Configures the EQ node for the given profile and enabled state.
    /// Call this whenever the user changes the profile selection or the enable toggle.
    func apply(profileID: UUID?, enabled: Bool) {
        guard enabled, let id = profileID, let profile = profiles.first(where: { $0.id == id }) else {
            bypassAll()
            return
        }
        configure(profile: profile)
    }

    // MARK: - Private

    private func bypassAll() {
        eqNode.globalGain = 0
        for band in eqNode.bands { band.bypass = true }
    }

    private func configure(profile: AutoEQProfile) {
        eqNode.globalGain = profile.preampGain

        let bands = eqNode.bands
        let count = min(profile.filters.count, Self.maxBands)

        if profile.filters.count > Self.maxBands {
            Logger.player.warning("[AutoEQ] Profile '\(profile.name)' has \(profile.filters.count) filters; only \(Self.maxBands) applied")
        }

        for i in 0..<count {
            let f = profile.filters[i]
            let band = bands[i]
            band.filterType = f.type.avFilterType
            band.frequency  = f.frequency
            band.gain       = f.gain
            band.bandwidth  = f.type.usesBandwidth ? qToBandwidth(f.q) : 1.0
            band.bypass     = f.bypass
        }
        for i in count..<Self.maxBands { bands[i].bypass = true }
    }

    /// Converts AutoEQ's Q factor to `AVAudioUnitEQ`'s bandwidth-in-octaves.
    /// Formula: bandwidth = 2 × asinh(1 / (2Q)) / ln(2)
    private func qToBandwidth(_ q: Float) -> Float {
        guard q > 0 else { return 1.0 }
        return max(0.05, min(5.0, Float(2.0 * asinh(1.0 / (2.0 * Double(q))) / log(2.0))))
    }
}

// MARK: - FilterType → AVAudioUnitEQ mapping

private extension AutoEQFilter.FilterType {
    var avFilterType: AVAudioUnitEQFilterType {
        switch self {
        case .peaking:   .parametric
        case .lowShelf:  .lowShelf
        case .highShelf: .highShelf
        case .lowPass:   .lowPass
        case .highPass:  .highPass
        case .notch:     .bandStop
        }
    }

    // LP/HP don't use bandwidth — AVAudioUnitEQ ignores it for those types.
    var usesBandwidth: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf, .notch: true
        case .lowPass, .highPass:                     false
        }
    }
}
