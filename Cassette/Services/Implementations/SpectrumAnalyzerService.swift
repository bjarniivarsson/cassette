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

    /// Called on the main actor whenever new FFT data is published — bypasses SwiftUI observation
    /// so the spectrogram renderer enqueues each column without waiting for a render cycle.
    /// Also called on decay ticks so the spectrogram continues scrolling after pause.
    var newChannelsHandler: (([[Float]]) -> Void)?

    // MARK: - Fixed constants

    // All scratch buffers are pre-allocated for the maximum supported FFT size so the FFT
    // size can be changed at runtime without reallocation. The actual size used per frame
    // is config.fftSize.rawValue (≤ maxFFTN).
    private static let maxFFTN    = 8192
    private static let maxLog2n   = vDSP_Length(13) // log2(8192)
    private static let maxChannels = 2
    private static let maxBinCount = 40

    // MARK: - Live config (written on main actor, read on tap thread — benign data race)

    private(set) var config: SpectrumAnalyzerConfig = .default

    // MARK: - Private state

    private let mixerNode: AVAudioMixerNode
    private var isRunning = false
    private var decayTimer: Timer?
    // Exponential decay: values reach 1% of their original level after 1 second of silence.
    // Per-tick factor = decayPerSecond^(1/fps).
    private static let decayPerSecond: Float = 0.01

    // FFT scratch buffers — pre-allocated for the maximum FFT size; accessed only from the
    // single tap-callback thread.
    private let fftSetup: FFTSetup?
    private var window: [Float]
    private var windowedBuffer: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudeBuffer: [Float]
    // Reassignment buffers — only used when config.useReassignment is true.
    private var derivWindow: [Float]           // numerical derivative of the Hann window
    private var derivWindowedBuffer: [Float]   // signal × derivWindow
    private var derivRealBuffer: [Float]       // Re(X_D) from derivative FFT
    private var derivImagBuffer: [Float]       // Im(X_D) from derivative FFT
    private var crossImagBuffer: [Float]       // Im(X_D · conj(X)) per bin, vectorized pre-scatter
    private var reassignedMagBuffer: [Float]   // scatter target for power accumulation
    // Sliding-window FFT state for spectrogram mode: each channel keeps the last maxFFTN samples
    // so the full-resolution FFT runs over a fresh window every spectrogramHop new samples.
    private var windowBuffer: [[Float]]
    private var windowFilled: Int = 0
    // Hop size for the spectrogram sliding window. Set in start() from the mixer's sample rate
    // to target exactly 30 FFT frames/sec; each frame is rendered as a 2-pt-wide strip at 60
    // pt/sec scroll speed, so production and consumption rates match.
    private var spectrogramHop: Int = 1600  // default for 48 kHz; overwritten in start()

    // Per-channel smoothing state — always maxBinCount×maxChannels so no resize is needed
    // when the user changes the bin count at runtime.
    private var smoothed: [[Float]]

    private var lastPublishTime: TimeInterval = 0
    // Per-bin-count precomputed mapping data.
    private struct BinConfig {
        let boundaries: [Int]  // integer FFT-bin edges (count+1 elements)
        let centers: [Float]   // exact float FFT-bin centre for each output bin
    }
    // Keyed [fftN][binCount] — bin boundaries depend on frequency resolution.
    private let allBinConfig: [Int: [Int: BinConfig]]

    // MARK: - Init / deinit

    init(mixerNode: AVAudioMixerNode, config: SpectrumAnalyzerConfig = .default) {
        self.mixerNode = mixerNode
        self.config = config

        let maxN = Self.maxFFTN

        // Build the Hann window for the maximum FFT size; smaller FFT sizes use the first n
        // elements. @Observable wraps stored-property inout access through the observation
        // registrar, so we build into locals and assign once all stored properties are init'd.
        var localWindow = [Float](repeating: 0, count: maxN)
        vDSP_hann_window(&localWindow, vDSP_Length(maxN), Int32(vDSP_HANN_NORM))

        // Numerical derivative of the Hann window via centred finite difference.
        // h'[n] ≈ (h[n+1] − h[n−1]) / 2; endpoints remain 0 (window is 0 at both ends).
        var localDerivWindow = [Float](repeating: 0, count: maxN)
        for i in 1..<(maxN - 1) { localDerivWindow[i] = (localWindow[i + 1] - localWindow[i - 1]) * 0.5 }

        window = localWindow
        derivWindow = localDerivWindow
        windowedBuffer = [Float](repeating: 0, count: maxN)
        derivWindowedBuffer = [Float](repeating: 0, count: maxN)
        realBuffer = [Float](repeating: 0, count: maxN / 2)
        imagBuffer = [Float](repeating: 0, count: maxN / 2)
        magnitudeBuffer = [Float](repeating: 0, count: maxN / 2)
        derivRealBuffer = [Float](repeating: 0, count: maxN / 2)
        derivImagBuffer = [Float](repeating: 0, count: maxN / 2)
        crossImagBuffer = [Float](repeating: 0, count: maxN / 2)
        reassignedMagBuffer = [Float](repeating: 0, count: maxN / 2)
        windowBuffer = Array(repeating: [Float](repeating: 0, count: maxN), count: Self.maxChannels)
        smoothed = Array(
            repeating: Array(repeating: 0, count: Self.maxBinCount),
            count: Self.maxChannels
        )
        // Setup supports all FFT sizes up to maxLog2n; smaller sizes reuse the same setup.
        fftSetup = vDSP_create_fftsetup(Self.maxLog2n, FFTRadix(kFFTRadix2))

        // Precompute log-spaced bin config for every (fftSize, binCount) combination.
        // lo/hi are FFT bin indices spanning ~21 Hz – 20 kHz.
        // hi is derived as 930/1024 of nyquistBins — the fraction that mapped to 20 kHz
        // at 44.1 kHz with a 2048-point FFT — so it scales correctly with any FFT size.
        allBinConfig = Dictionary(uniqueKeysWithValues: SpectrumFFTSize.allCases.map { fftSizeCase in
            let n = fftSizeCase.rawValue
            let nyquistBins = n / 2
            let lo = Double(1), hi = Double(nyquistBins) * (930.0 / 1024.0)
            let byBinCount = Dictionary(uniqueKeysWithValues: SpectrumBinDetail.allCases.map { detail in
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
            return (n, byBinCount)
        })
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // MARK: - Control

    func start() {
        guard config.isEnabled, !isRunning else { return }
        isRunning = true
        if config.targetFPS > 30 {
            let sr = mixerNode.outputFormat(forBus: 0).sampleRate
            spectrogramHop = max(256, Int((sr / 30.0).rounded()))
        }
        let tapHint = UInt32(config.targetFPS > 30 ? spectrogramHop : config.fftSize.rawValue)
        mixerNode.installTap(onBus: 0, bufferSize: tapHint, format: nil) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }
        let timer = Timer(timeInterval: 1.0 / config.targetFPS, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickDecay() }
        }
        RunLoop.main.add(timer, forMode: .common)
        decayTimer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        mixerNode.removeTap(onBus: 0)
        decayTimer?.invalidate()
        decayTimer = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.channels = self.channels.map { _ in Array(repeating: 0, count: Self.maxBinCount) }
        }
    }

    @MainActor private func tickDecay() {
        // lastPublishTime is nonisolated(unsafe) — benign race, same pattern as config.
        // Threshold must exceed the longest possible gap between tap callbacks during playback.
        // At 4096 samples / 44100 Hz ≈ 93 ms; 200 ms gives comfortable headroom.
        guard CACurrentMediaTime() - lastPublishTime > 0.20 else { return }
        let fps = Float(config.targetFPS)
        let factor = pow(Self.decayPerSecond, 1.0 / fps)
        channels = channels.map { ch in ch.map { $0 * factor } }
        newChannelsHandler?(channels)
    }

    /// Push updated user settings into the service. Called from the main actor when any setting changes.
    func updateConfig(_ newConfig: SpectrumAnalyzerConfig) {
        let wasEnabled = config.isEnabled
        let oldFFTSize = config.fftSize
        let oldTargetFPS = config.targetFPS
        config = newConfig
        if wasEnabled && !newConfig.isEnabled {
            stop()
        } else if isRunning && (newConfig.fftSize != oldFFTSize || newConfig.targetFPS != oldTargetFPS) {
            if newConfig.targetFPS != oldTargetFPS { windowFilled = 0 }
            mixerNode.removeTap(onBus: 0)
            let tapHint = UInt32(newConfig.targetFPS > 30 ? spectrogramHop : newConfig.fftSize.rawValue)
            mixerNode.installTap(onBus: 0, bufferSize: tapHint, format: nil) { [weak self] buffer, _ in
                self?.processTap(buffer: buffer)
            }
        }
        if isRunning && newConfig.targetFPS != oldTargetFPS {
            decayTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / newConfig.targetFPS, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tickDecay() }
            }
            RunLoop.main.add(timer, forMode: .common)
            decayTimer = timer
        }
    }

    // MARK: - Private

    private func processTap(buffer: AVAudioPCMBuffer) {
        guard let fftSetup, let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }

        let snapshot = config
        let frameCount = Int(buffer.frameLength)
        let channelCount = min(Int(buffer.format.channelCount), snapshot.showStereo ? Self.maxChannels : 1)

        if snapshot.targetFPS > 30 {
            // Spectrogram: proper hop-by-hop sliding window.
            // Loop through ALL new samples in spectrogramHop-sized steps so a large callback
            // buffer (e.g. 4096 samples) produces multiple FFT frames, not just one.
            // Each iteration advances the window by exactly 'take' samples.
            let n = snapshot.fftSize.rawValue
            let hop = spectrogramHop
            var srcOffset = 0

            while srcOffset < frameCount {
                let take = min(frameCount - srcOffset, hop - windowFilled)

                for ch in 0..<channelCount {
                    windowBuffer[ch].withUnsafeMutableBufferPointer { buf in
                        let p = buf.baseAddress!
                        memmove(p, p + take, (n - take) * MemoryLayout<Float>.size)
                        memcpy(p + (n - take), channelData[ch] + srcOffset,
                               take * MemoryLayout<Float>.size)
                    }
                }

                srcOffset += take
                windowFilled += take

                if windowFilled >= hop {
                    windowFilled = 0
                    var result = [[Float]]()
                    result.reserveCapacity(channelCount)
                    for ch in 0..<channelCount {
                        let bins = windowBuffer[ch].withUnsafeBufferPointer { ptr in
                            fftBins(for: ptr.baseAddress!, usable: n,
                                    channel: ch, fftSetup: fftSetup, config: snapshot)
                        }
                        result.append(bins)
                    }
                    lastPublishTime = CACurrentMediaTime()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.channels = result
                        self.newChannelsHandler?(result)
                    }
                }
            }
        } else {
            // Standard path: time-gated, process each tap buffer independently.
            let now = CACurrentMediaTime()
            guard now - lastPublishTime >= 1.0 / snapshot.targetFPS else { return }
            let usable = min(frameCount, snapshot.fftSize.rawValue)
            var result = [[Float]]()
            result.reserveCapacity(channelCount)
            for ch in 0..<channelCount {
                result.append(fftBins(for: channelData[ch], usable: usable,
                                      channel: ch, fftSetup: fftSetup, config: snapshot))
            }
            lastPublishTime = now
            Task { @MainActor [weak self] in self?.channels = result }
        }
    }

    private func fftBins(for samples: UnsafePointer<Float>, usable: Int, channel: Int,
                         fftSetup: FFTSetup, config: SpectrumAnalyzerConfig) -> [Float] {
        let n = config.fftSize.rawValue
        let log2n = vDSP_Length(config.fftSize.log2n)
        // Hann window; zero-pad tail if buffer is shorter than n.
        vDSP_vclr(&windowedBuffer, 1, vDSP_Length(n))
        vDSP_vmul(samples, 1, window, 1, &windowedBuffer, 1, vDSP_Length(usable))

        // Pack real signal into split-complex format for vDSP real FFT.
        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                windowedBuffer.withUnsafeBytes { raw in
                    let complexPtr = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudeBuffer, 1, vDSP_Length(n / 2))
                }
            }
        }

        // Time-frequency reassignment: scatter each bin's power to its instantaneous frequency.
        // Run before normalization so magnitudeBuffer still holds raw |X[k]|² from vDSP_zvmags,
        // avoiding the per-iteration re² + im² recomputation. The cross-spectrum imaginary part
        // Im(X_D·conj(X)) = derivImag·real − derivReal·imag is vectorized with vDSP_vmmsb for
        // all bins at once before the scatter loop.
        if config.useReassignment {
            vDSP_vclr(&derivWindowedBuffer, 1, vDSP_Length(n))
            vDSP_vmul(samples, 1, derivWindow, 1, &derivWindowedBuffer, 1, vDSP_Length(usable))
            derivRealBuffer.withUnsafeMutableBufferPointer { dRealPtr in
                derivImagBuffer.withUnsafeMutableBufferPointer { dImagPtr in
                    derivWindowedBuffer.withUnsafeBytes { raw in
                        let complexPtr = raw.bindMemory(to: DSPComplex.self).baseAddress!
                        var split = DSPSplitComplex(realp: dRealPtr.baseAddress!,
                                                    imagp: dImagPtr.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }
            let halfN = n / 2
            let factor = Float(n) / (2 * .pi)  // converts angular displacement → bin units
            // Vectorized: crossImagBuffer[k] = derivImag[k]·real[k] − derivReal[k]·imag[k]
            derivImagBuffer.withUnsafeBufferPointer { diPtr in
                realBuffer.withUnsafeBufferPointer { rePtr in
                    derivRealBuffer.withUnsafeBufferPointer { drPtr in
                        imagBuffer.withUnsafeBufferPointer { imPtr in
                            crossImagBuffer.withUnsafeMutableBufferPointer { crossPtr in
                                vDSP_vmmsb(diPtr.baseAddress!, 1,
                                           rePtr.baseAddress!, 1,
                                           drPtr.baseAddress!, 1,
                                           imPtr.baseAddress!, 1,
                                           crossPtr.baseAddress!, 1,
                                           vDSP_Length(halfN))
                            }
                        }
                    }
                }
            }
            vDSP_vclr(&reassignedMagBuffer, 1, vDSP_Length(halfN))
            for k in 1..<(halfN - 1) {
                // magnitudeBuffer[k] = re²+im² here (raw, pre-normalization).
                let power = magnitudeBuffer[k]
                guard power > 1e-6 else { continue }
                // ω̂ = k + (N/2π)·Im(X_D[k]·conj(X[k])) / |X[k]|²
                let kHat = Float(k) + factor * crossImagBuffer[k] / power
                let kInt = Int(kHat.rounded())
                guard kInt > 0, kInt < halfN - 1 else { continue }
                reassignedMagBuffer[kInt] += power
            }
            magnitudeBuffer.withUnsafeMutableBufferPointer { dst in
                reassignedMagBuffer.withUnsafeBufferPointer { src in
                    _ = memcpy(dst.baseAddress!, src.baseAddress!, halfN * MemoryLayout<Float>.size)
                }
            }
        }

        // Normalize squared magnitudes: 1/(n²) maps vDSP_zvmags output to [0, 1] scale.
        var scale = Float(1) / Float(n * n)
        vDSP_vsmul(magnitudeBuffer, 1, &scale, &magnitudeBuffer, 1, vDSP_Length(n / 2))

        // Map FFT magnitudes to output bins.
        // Bins spanning ≥2 FFT bins use vDSP_maxv (peak energy in range).
        // Narrow bins (0 or 1 FFT bin wide) use linear interpolation at the bin's exact float
        // centre — this prevents the first several output bins from producing identical values
        // when multiple log-spaced output bins collapse to the same integer FFT bin.
        let binCount = config.binCount
        let binCfg = allBinConfig[n]?[binCount] ?? allBinConfig[2048]![20]!
        let nyquistBins = n / 2
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
