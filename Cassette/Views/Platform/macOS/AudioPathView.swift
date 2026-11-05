// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import SwiftSonic

struct AudioPathView: View {
    @Environment(\.appContainer) private var container

    let track: DisplayableSong?

    @State private var resolvedProfile: AutoEQProfile? = nil
    @State private var resolvedServerType: String? = nil

    private var outputDeviceState: OutputDeviceState? { container?.outputDeviceState }
    private var outputDeviceName: String? { outputDeviceState?.currentDeviceName }
    private var outputSampleRate: Double? { outputDeviceState?.currentSampleRate }
    private var outputBitDepth: UInt32? { outputDeviceState?.currentBitDepth }
    private var outputIsFloat: Bool { outputDeviceState?.currentIsFloat ?? false }
    private var outputChannels: UInt32? { outputDeviceState?.currentChannels }

    var body: some View {
        VStack(spacing: 0) {
            sourceStage
            if let ts = track?.transcodedFormat, ts != track?.audioFormat {
                connector
                transcodeStage(to: ts)
            }
            connector
            deliveryStage
            connector
            float32Stage

            if container?.replayGainSettings.enabled == true {
                connector
                replayGainStage
            }

            if autoEQEffectivelyActive {
                connector
                autoEQStage
            }

            if let duration = container?.crossfadeSettings.duration, duration > 0, !crossfadeSuppressed {
                connector
                crossfadeStage(duration: duration)
            }

            if !outputConversionSame {
                connector
                outputConversionStage
            }
            connector
            outputStage
        }
        .padding(14)
        .frame(minWidth: 340, maxWidth: 460)
        .task(id: container?.autoEQSettings.selectedProfileID) {
            await resolveProfileName()
        }
        .task {
            await resolveServerType()
        }
    }

    // MARK: - Stages

    private var sourceStage: some View {
        let codec = track?.audioFormat ?? "—"

        let lossless: Set<String> = ["FLAC", "ALAC", "WAV", "WAVE", "AIFF", "AIF", "APE", "WV", "WAVPACK", "TTA"]
        let isLossless = lossless.contains(track?.audioFormat?.uppercased() ?? "")

        var tokens: [String] = [codec]
        if !isLossless, let br = track?.bitRate { tokens.append("\(br) kbps") }
        if let bd = track?.bitDepth { tokens.append("\(bd)-bit PCM") }
        if let sr = track?.samplingRate {
            let khz = Double(sr) / 1000.0
            tokens.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        if let ch = track?.channelCount {
            tokens.append(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch) ch")
        }

        return card(
            icon: "waveform",
            title: "Source",
            detail: tokens.joined(separator: " · ")
        )
    }

    private var deliveryStage: some View {
        let isDownloaded = track?.isDownloaded == true
        return card(
            icon: isDownloaded ? "arrow.down.circle.fill" : "antenna.radiowaves.left.and.right",
            title: isDownloaded ? "Downloaded" : "Stream",
            detail: isDownloaded ? nil : resolvedServerType
        )
    }

    private var replayGainStage: some View {
        let settings = container?.replayGainSettings
        let mode = settings?.mode == .album ? "Album" : "Track"
        let gainText: String? = track.map { t in
            let g = ReplayGainService.computeGain(
                enabled: settings?.enabled ?? false,
                mode: settings?.mode ?? .track,
                preAmp: settings?.preAmp ?? 0,
                preventClipping: settings?.preventClipping ?? true,
                trackGain: t.replayGainTrackGain,
                trackPeak: t.replayGainTrackPeak,
                albumGain: t.replayGainAlbumGain,
                albumPeak: t.replayGainAlbumPeak,
                baseGain: t.replayGainBaseGain,
                fallbackGain: t.replayGainFallbackGain
            )
            return String(format: g >= 0 ? "+%.1f dB" : "%.1f dB", g)
        }
        let detail = gainText.map { "\(mode) · \($0)" } ?? mode
        return card(icon: "dial.medium", title: "ReplayGain", detail: detail)
    }

    private var autoEQStage: some View {
        let profile = resolvedProfile
        let activeFilters = profile?.filters.filter { !$0.bypass }.count ?? 0
        var tokens: [String] = ["\(activeFilters) filters"]
        if let gain = profile?.preampGain {
            tokens.insert(String(format: gain >= 0 ? "+%.1f dB preamp" : "%.1f dB preamp", gain), at: 0)
        }
        return card(
            icon: "headphones",
            title: "AutoEQ",
            subtitle: profile?.name,
            detail: tokens.joined(separator: " · ")
        )
    }

    private func transcodeStage(to format: String) -> some View {
        let from = track?.audioFormat ?? "?"
        var tokens: [String] = ["\(from) → \(format)"]
        if let br = track?.bitRate { tokens.append("\(br) kbps") }
        return card(icon: "arrow.triangle.2.circlepath", title: "Transcode", detail: tokens.joined(separator: " · "))
    }

    private var float32Stage: some View {
        let sourceChannels = track?.channelCount ?? 0
        let downmix = sourceChannels > 2
        let sourcePart = track?.bitDepth.map { "\($0)-bit PCM" } ?? "PCM"
        let source = downmix ? "\(sourcePart) · \(sourceChannels)ch" : sourcePart
        let dest = downmix ? "32-bit Float · Stereo" : "32-bit Float"
        return card(icon: "function", title: "Conversion", detail: "\(source) → \(dest)")
    }

    private var autoEQEffectivelyActive: Bool {
        guard let settings = container?.autoEQSettings, resolvedProfile != nil else { return false }
        return settings.isEffectivelyEnabled(currentDeviceUID: outputDeviceState?.currentDeviceUID)
    }

    private var crossfadeSuppressed: Bool {
        guard container?.crossfadeSettings.disableForGapless == true else { return false }
        let state = container?.playerState
        let currentIndex = state?.currentIndex ?? 0
        let queue = state?.queue ?? []
        guard currentIndex + 1 < queue.count else { return false }
        let next = queue[currentIndex + 1]
        return PlayerService.isGaplessPair(
            currentAlbumId: track?.albumId,
            currentTrackNumber: track?.trackNumber,
            nextAlbumId: next.albumId,
            nextTrackNumber: next.trackNumber
        )
    }

    private func crossfadeStage(duration: Double) -> some View {
        let label = duration == duration.rounded() ? "\(Int(duration)) s" : String(format: "%.1f s", duration)
        return card(icon: "arrow.2.squarepath", title: "Crossfade", detail: label)
    }

    private var outputConversionSame: Bool {
        guard let outDepth = outputBitDepth, let outRate = outputSampleRate, let outCh = outputChannels else {
            return true
        }
        let internalRate = track?.samplingRate.map { Double($0) }
        let rateSame = internalRate == nil || abs((internalRate ?? outRate) - outRate) < 1.0
        return outDepth == 32 && outputIsFloat && outCh == 2 && rateSame
    }

    private var outputConversionStage: some View {
        var fromTokens: [String] = []
        var toTokens: [String] = []

        // Format / bit depth: internal is always 32-bit Float
        let outDepth = outputBitDepth ?? 32
        if outDepth != 32 || !outputIsFloat {
            fromTokens.append("32-bit Float")
            toTokens.append(outputIsFloat ? "\(outDepth)-bit Float" : "\(outDepth)-bit PCM")
        }

        // Sample rate
        if let inRate = track?.samplingRate.map({ Double($0) }),
           let outRate = outputSampleRate, abs(inRate - outRate) >= 1.0 {
            let fmt: (Double) -> String = { r in
                let k = r / 1000.0
                return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
            }
            fromTokens.append(fmt(inRate))
            toTokens.append(fmt(outRate))
        }

        // Channels: internal is always stereo
        if let outCh = outputChannels, outCh != 2 {
            fromTokens.append("Stereo")
            toTokens.append(outCh == 1 ? "Mono" : "\(outCh)ch")
        }

        let detail = "\(fromTokens.joined(separator: " · ")) → \(toTokens.joined(separator: " · "))"
        return card(icon: "arrow.left.arrow.right", title: "Conversion", detail: detail)
    }

    private var outputStage: some View {
        var tokens: [String] = []
        if let bd = outputBitDepth, bd > 0 {
            tokens.append(outputIsFloat ? "\(bd)-bit Float" : "\(bd)-bit PCM")
        }
        if let sr = outputSampleRate {
            let khz = sr / 1000.0
            tokens.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        if let ch = outputChannels {
            tokens.append(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch) ch")
        }
        return card(
            icon: "speaker.wave.2.fill",
            title: "Output",
            subtitle: outputDeviceName,
            detail: tokens.isEmpty ? nil : tokens.joined(separator: " · ")
        )
    }

    // MARK: - Layout helpers

    private func card(icon: String, title: String, subtitle: String? = nil, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }

    private var connector: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(spacing: 1) {
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 1, height: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 1, height: 6)
            }
            Spacer()
        }
        .frame(height: 20)
    }

    // MARK: - Data resolution

    private func resolveServerType() async {
        guard let service = container?.serverService,
              let client = try? await service.makeSwiftSonicClient(),
              let caps = try? await client.loadCapabilities(),
              let type_ = caps.serverType else { return }
        resolvedServerType = type_.capitalized
    }

    private func resolveProfileName() async {
        guard let settings = container?.autoEQSettings,
              settings.isEnabled,
              let profileID = settings.selectedProfileID,
              let service = container?.autoEQService else {
            resolvedProfile = nil
            return
        }
        let profiles = await service.profiles
        resolvedProfile = profiles.first(where: { $0.id == profileID })
    }
}
#endif
