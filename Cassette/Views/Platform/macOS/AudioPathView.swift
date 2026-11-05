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
    private var outputIsOSManaged: Bool { outputDeviceState?.currentIsOSManaged ?? false }
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

            if let rgi = replayGainInfo {
                connector
                replayGainStage(info: rgi)
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

        let isHiRes = isLossless
            && (track?.bitDepth ?? 0) >= 24
            && (track?.samplingRate ?? 0) >= 96000
        let qualityLabel: String? = isHiRes ? "Hi-Res Lossless" : isLossless ? "Lossless" : nil

        var tokens: [String] = [codec]
        if !isLossless, let br = track?.bitRate { tokens.append("\(br) kbps") }
        if let bd = track?.bitDepth { tokens.append("\(bd)-bit PCM") }
        if let sr = track?.samplingRate {
            let khz = Double(sr) / 1000.0
            tokens.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        if let ch = track?.channelCount {
            tokens.append(channelLabel(ch))
        }

        return card(
            icon: "waveform",
            title: "Source",
            subtitle: qualityLabel,
            detail: tokens.joined(separator: " · ")
        )
    }

    private var deliveryStage: some View {
        let isDownloaded = track?.isDownloaded == true
        return card(
            icon: isDownloaded ? "arrow.down.circle.fill" : "antenna.radiowaves.left.and.right",
            title: isDownloaded ? "Downloaded" : "Stream",
            detail: isDownloaded ? nil : resolvedServerType.map { "\($0) → Cassette" }
        )
    }

    private var replayGainInfo: (raw: Float, preAmp: Double, total: Float)? {
        guard let settings = container?.replayGainSettings, settings.enabled, let t = track else { return nil }
        let args = (mode: settings.mode, preventClipping: settings.preventClipping,
                    trackGain: t.replayGainTrackGain, trackPeak: t.replayGainTrackPeak,
                    albumGain: t.replayGainAlbumGain, albumPeak: t.replayGainAlbumPeak,
                    baseGain: t.replayGainBaseGain, fallbackGain: t.replayGainFallbackGain)
        let total = ReplayGainService.computeGain(
            enabled: true, mode: args.mode, preAmp: settings.preAmp,
            preventClipping: args.preventClipping,
            trackGain: args.trackGain, trackPeak: args.trackPeak,
            albumGain: args.albumGain, albumPeak: args.albumPeak,
            baseGain: args.baseGain, fallbackGain: args.fallbackGain)
        guard total != 0 else { return nil }
        let raw = ReplayGainService.computeGain(
            enabled: true, mode: args.mode, preAmp: 0,
            preventClipping: args.preventClipping,
            trackGain: args.trackGain, trackPeak: args.trackPeak,
            albumGain: args.albumGain, albumPeak: args.albumPeak,
            baseGain: args.baseGain, fallbackGain: args.fallbackGain)
        return (raw: raw, preAmp: settings.preAmp, total: total)
    }

    private func replayGainStage(info: (raw: Float, preAmp: Double, total: Float)) -> some View {
        let modeLabel = container?.replayGainSettings.mode == .album ? "Album" : "Track"
        func fmt(_ v: Double) -> String {
            String(format: v >= 0 ? "+%.1fdB" : "%.1fdB", v)
        }
        var tokens = ["Gain", "\(fmt(Double(info.raw))) (\(modeLabel))"]
        if info.preAmp != 0 {
            tokens += ["\(fmt(info.preAmp)) (Pre-Amp)", "Total", fmt(Double(info.total))]
        }
        return card(icon: "dial.medium", title: "ReplayGain", detail: tokens.joined(separator: " · "))
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
        let source = downmix ? "\(sourcePart) · \(channelLabel(sourceChannels))" : sourcePart
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
        guard currentIndex < queue.count, currentIndex + 1 < queue.count else { return false }
        let current = queue[currentIndex]
        let next = queue[currentIndex + 1]
        return PlayerService.isGaplessPair(
            currentAlbumId: current.albumId,
            currentTrackNumber: current.trackNumber,
            nextAlbumId: next.albumId,
            nextTrackNumber: next.trackNumber
        )
    }

    private func crossfadeStage(duration: Double) -> some View {
        let label = duration == duration.rounded() ? "\(Int(duration)) s" : String(format: "%.1f s", duration)
        return card(icon: "arrow.2.squarepath", title: "Crossfade", detail: label)
    }

    private var outputConversionSame: Bool {
        guard let outRate = outputSampleRate, let outCh = outputChannels else { return true }
        let internalRate = track?.samplingRate.map { Double($0) }
        let rateSame = internalRate == nil || abs((internalRate ?? outRate) - outRate) < 1.0
        let channelsSame = outCh == 2
        // If bit depth is unknown (OS-managed device), treat format as same — can't compare.
        let formatSame = outputBitDepth.map { $0 == 32 && outputIsFloat } ?? true
        return rateSame && channelsSame && formatSame
    }

    private var outputConversionStage: some View {
        var fromTokens: [String] = []
        var toTokens: [String] = []

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
            toTokens.append(channelLabel(Int(outCh)))
        }

        // Format / bit depth: only shown for a known output format that differs from
        // internal Float32. OS-managed devices (nil bit depth) are never shown here —
        // Float32 → Float32 (OS) is not a real conversion.
        if let outDepth = outputBitDepth, outDepth != 32 || !outputIsFloat {
            fromTokens.insert("32-bit Float", at: 0)
            toTokens.insert(outputIsFloat ? "\(outDepth)-bit Float" : "\(outDepth)-bit PCM", at: 0)
        }

        let detail = "\(fromTokens.joined(separator: " · ")) → \(toTokens.joined(separator: " · "))"
        return card(icon: "function", title: "Conversion", detail: detail)
    }

    private var outputStage: some View {
        var tokens: [String] = []
        if let bd = outputBitDepth, bd > 0 {
            tokens.append(outputIsFloat ? "\(bd)-bit Float" : "\(bd)-bit PCM")
        } else if outputIsOSManaged {
            tokens.append("32-bit Float (OS)")
        }
        if let sr = outputSampleRate {
            let khz = sr / 1000.0
            tokens.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        if let ch = outputChannels {
            tokens.append(channelLabel(Int(ch)))
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

    private func channelLabel(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 4: return "Quad"
        case 5: return "5.0 Surround"
        case 6: return "5.1 Surround"
        case 7: return "6.1 Surround"
        case 8: return "7.1 Surround"
        default: return "\(count)ch"
        }
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
