// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import Accelerate
import Observation

/// FFT spectrum analyzer that installs an audio tap on the main mixer node.
/// Start/stop it when the full-screen player appears/disappears — zero overhead when stopped.
/// All settings are live-updated via updateConfig(_:) from the main actor; the tap callback
/// reads them through nonisolated(unsafe) var config (benign data race: worst case is one
/// stale visual frame on a settings change).
@Observable
final class SpectrumAnalyzerService {
    /// Per-channel magnitude bins. channels[0] = left, channels[1] = right (when present).
    /// Each inner array has config.binCount elements in 0.0–1.0, updated at ~30 fps while running.
    private(set) var channels: [[Float]] = [Array(repeating: 0, count: 20)]

    // MARK: - Fixed constants

    private static let fftN       = 2048
    private static let log2n      = vDSP_Length(11) // log2(2048)
    private static let maxChannels = 2
    private static let maxBinCount = 40

    // MARK: - Live config (written on main actor, read on tap thread — benign data race)

    private(set) var config: SpectrumAnalyzerConfig = .default

    // MARK: - Private state

    private let mixerNode: AVAudioMixerNode
    private var isRunning = false

    // FFT scratch buffers — pre-allocated for the maximum FFT size; accessed only from the
    // single tap-callback thread.
    private let fftSetup: FFTSetup?
    private var window: [Float]
    private var windowedBuffer: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudeBuffer: [Float]

    // Per-channel smoothing state — always maxBinCount×maxChannels so no resize is needed
    // when the user changes the bin count at runtime.
    private var smoothed: [[Float]]

    private var lastPublishTime: TimeInterval = 0
    // Per-bin-count precomputed mapping data.
    private struct BinConfig {
        let boundaries: [Int]  // integer FFT-bin edges (count+1 elements)
        let centers: [Float]   // exact float FFT-bin centre for each output bin
    }
    private let allBinConfig: [Int: BinConfig]
    // Precomputed: 1 / (fftN * fftN) — avoids a division per tap callback.
    private let normalizeScale: Float

    // MARK: - Init / deinit

    init(mixerNode: AVAudioMixerNode, config: SpectrumAnalyzerConfig = .default) {
        self.mixerNode = mixerNode
        self.config = config

        let n = Self.fftN

        // Build the Hann window into a local variable: @Observable wraps every stored-property
        // inout access through the observation registrar, which requires all stored properties to
        // be initialized first. Using a local avoids that check, then we assign normally.
        var localWindow = [Float](repeating: 0, count: n)
        vDSP_hann_window(&localWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        window = localWindow
        windowedBuffer = [Float](repeating: 0, count: n)
        realBuffer = [Float](repeating: 0, count: n / 2)
        imagBuffer = [Float](repeating: 0, count: n / 2)
        magnitudeBuffer = [Float](repeating: 0, count: n / 2)
        smoothed = Array(
            repeating: Array(repeating: 0, count: Self.maxBinCount),
            count: Self.maxChannels
        )
        normalizeScale = Float(1) / Float(n * n)
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))

        // Precompute log-spaced bin config for every supported bin count so we never recompute
        // at runtime when the user changes the setting.
        // lo/hi are FFT bin indices: bin 1 ≈ 21 Hz, bin 930 ≈ 20 kHz (at 44100 Hz / 2048 samples).
        let nyquistBins = n / 2
        let lo = Double(1), hi = Double(930)
        allBinConfig = Dictionary(uniqueKeysWithValues: SpectrumBinDetail.allCases.map { detail in
            let count = detail.rawValue
            let boundaries = (0...count).map { i in
                max(1, min(nyquistBins - 1, Int(lo * pow(hi / lo, Double(i) / Double(count)))))
            }
            // Float centre of each output bin — used for sub-bin interpolation when multiple
            // output bins collapse to the same integer FFT bin (common in the low-frequency range).
            let centers = (0..<count).map { i in
                Float(lo * pow(hi / lo, (Double(i) + 0.5) / Double(count)))
            }
            return (count, BinConfig(boundaries: boundaries, centers: centers))
        })
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // MARK: - Control

    func start() {
        guard config.isEnabled, !isRunning else { return }
        isRunning = true
        mixerNode.installTap(onBus: 0, bufferSize: UInt32(Self.fftN), format: nil) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        mixerNode.removeTap(onBus: 0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.channels = self.channels.map { _ in Array(repeating: 0, count: Self.maxBinCount) }
        }
    }

    /// Push updated user settings into the service. Called from the main actor when any setting changes.
    func updateConfig(_ newConfig: SpectrumAnalyzerConfig) {
        let wasEnabled = config.isEnabled
        config = newConfig
        // If the analyzer was running but is now disabled, stop. The view handles the
        // reverse (re-enabling while open) via its own .onChange observer.
        if wasEnabled && !newConfig.isEnabled {
            stop()
        }
    }

    // MARK: - Private

    private func processTap(buffer: AVAudioPCMBuffer) {
        // Gate on time before doing any FFT work — avoids running the full pipeline on
        // frames that won't be published (matters at >44 kHz or small system-delivered buffers).
        let now = CACurrentMediaTime()
        guard now - lastPublishTime >= 1.0 / 30.0 else { return }

        guard let fftSetup, let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }

        let snapshot = config  // single read of the volatile config
        let usable = min(Int(buffer.frameLength), Self.fftN)
        let channelCount = min(Int(buffer.format.channelCount), snapshot.showStereo ? Self.maxChannels : 1)

        var result = [[Float]]()
        result.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            result.append(fftBins(for: channelData[ch], usable: usable, channel: ch,
                                  fftSetup: fftSetup, config: snapshot))
        }

        lastPublishTime = now

        Task { @MainActor [weak self] in
            self?.channels = result
        }
    }

    private func fftBins(for samples: UnsafePointer<Float>, usable: Int, channel: Int,
                         fftSetup: FFTSetup, config: SpectrumAnalyzerConfig) -> [Float] {
        let n = Self.fftN
        // Hann window; zero-pad tail if buffer is shorter than fftN.
        vDSP_vclr(&windowedBuffer, 1, vDSP_Length(n))
        vDSP_vmul(samples, 1, window, 1, &windowedBuffer, 1, vDSP_Length(usable))

        // Pack real signal into split-complex format for vDSP real FFT.
        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                windowedBuffer.withUnsafeBytes { raw in
                    let complexPtr = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                    vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudeBuffer, 1, vDSP_Length(n / 2))
                }
            }
        }

        // Normalize squared magnitudes (precomputed constant avoids per-call division).
        var scale = normalizeScale
        vDSP_vsmul(magnitudeBuffer, 1, &scale, &magnitudeBuffer, 1, vDSP_Length(n / 2))

        // Map FFT magnitudes to output bins.
        // Bins spanning ≥2 FFT bins use vDSP_maxv (peak energy in range).
        // Narrow bins (0 or 1 FFT bin wide) use linear interpolation at the bin's exact float
        // centre — this prevents the first several output bins from producing identical values
        // when multiple log-spaced output bins collapse to the same integer FFT bin.
        let binCount = config.binCount
        let binCfg = allBinConfig[binCount] ?? allBinConfig[20]!
        let nyquistBins = Self.fftN / 2
        var bins = [Float](repeating: 0, count: binCount)
        magnitudeBuffer.withUnsafeBufferPointer { ptr in
            for i in 0..<binCount {
                let lo = binCfg.boundaries[i], hi = binCfg.boundaries[i + 1]
                if hi - lo >= 2 {
                    vDSP_maxv(ptr.baseAddress! + lo, 1, &bins[i], vDSP_Length(hi - lo))
                } else {
                    let center = binCfg.centers[i]
                    let f = Int(center)
                    let t = center - Float(f)
                    let f0 = max(0, min(nyquistBins - 2, f))
                    bins[i] = ptr[f0] * (1 - t) + ptr[f0 + 1] * t
                }
            }
        }

        // Convert to dB, map to 0–1 against the configured floor. Fast attack, instant decay.
        let dbFloor = config.dbFloor
        let dbRange: Float = -dbFloor  // floor is negative; range spans from floor to 0 dBFS
        let attack = config.attackCoefficient
        let decay = Float(1) - attack
        for i in 0..<binCount {
            let dB = max(dbFloor, 10 * log10f(max(bins[i], 1e-10)))
            let norm = (dB - dbFloor) / dbRange
            if norm > smoothed[channel][i] {
                smoothed[channel][i] = smoothed[channel][i] * decay + norm * attack
            } else {
                smoothed[channel][i] = norm
            }
            bins[i] = smoothed[channel][i]
        }

        return bins
    }
}
