// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import AppKit
import Observation

/// Scrolling spectrogram: time flows left → right, frequency bottom (low) → top (high).
/// A fixed 40pt-high image is pinned to the bottom of the view. A 30 fps timer drives
/// column appends independently of the analyzer's publish rate. On resize the old pixel
/// data is copied right-aligned into the new buffer (oldest data lost on the left).
struct SpectrogramSpectrumAnalyzerView: View {
    @Environment(\.appContainer) private var container

    private static let imageHeight: CGFloat = 80

    @State private var renderer = SpectrogramRenderer()

    var body: some View {
        GeometryReader { geo in
            if let cgImage = renderer.displayImage {
                Image(nsImage: NSImage(cgImage: cgImage,
                                      size: NSSize(width: geo.size.width,
                                                   height: Self.imageHeight)))
                    .resizable()
                    .frame(width: geo.size.width, height: Self.imageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear {
            let renderer = renderer
            container?.spectrumAnalyzer.newChannelsHandler = { [weak renderer] ch in
                renderer?.didReceiveChannels(ch)
            }
            renderer.start()
        }
        .onDisappear {
            container?.spectrumAnalyzer.newChannelsHandler = nil
            renderer.stop()
        }
        // Geometry is read here so the onChange fires on every layout pass.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size, initial: true) { _, size in
                        guard size.width > 0 else { return }
                        renderer.resize(viewWidth: size.width)
                    }
            }
        )
    }
}

// MARK: - Renderer

/// CADisplayLink requires an NSObject target; this trampoline forwards ticks to the renderer.
private final class DisplayLinkTarget: NSObject {
    weak var renderer: SpectrogramRenderer?
    @objc func tick(_ link: CADisplayLink) { renderer?.tick(link: link) }
}

@Observable
private final class SpectrogramRenderer {
    private(set) var displayImage: CGImage?
    // Buffer is always @2x so content survives moves between @1x and @2x displays.
    // AppKit scales the NSImage down automatically on @1x screens; the cost is negligible.
    private let displayScale: CGFloat = 2
    // Queue of incoming FFT results. The service may burst-produce several frames at once
    // (one per hop in a large buffer); enqueueing them lets the display-sync tick render
    // one column per vsync rather than coalescing all updates to the last result only.
    private var columnQueue: [[[Float]]] = []
    private static let maxQueueDepth = 5
    private var lastColumn: [Float]?
    // Logical-point scroll debt. Each tick adds elapsed × pointsPerSecond; each
    // stripWidthPoints consumed renders physicalColumns = round(stripWidthPoints × 2) = 4
    // physical columns. Scroll rate = pointsPerSecond logical pts/sec on any screen.
    private var scrollAccumulator: Double = 0
    private var lastTargetTimestamp: CFTimeInterval = 0
    // Scroll at 60 pt/sec; each FFT frame fills a 2-pt-wide strip.
    // Consumption rate = pointsPerSecond / stripWidthPoints = 30 FFT frames/sec,
    // which matches the service's hop = sampleRate/30 production rate.
    private static let pointsPerSecond: Double = 60
    private static let stripWidthPoints: Double = 2

    private var pixelBuffer: SpectrogramPixelBuffer?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?

    private static let imageHeight: CGFloat = 80

    func start() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget()
        target.renderer = self
        guard let link = NSScreen.main?.displayLink(
            target: target, selector: #selector(DisplayLinkTarget.tick(_:))
        ) else { return }
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkTarget = target
    }

    func didReceiveChannels(_ newChannels: [[Float]]) {
        if columnQueue.count < Self.maxQueueDepth {
            columnQueue.append(newChannels)
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        scrollAccumulator = 0
        lastTargetTimestamp = 0
    }

    func resize(viewWidth: CGFloat) {
        let pw = max(1, Int(viewWidth      * displayScale))
        let ph = max(1, Int(Self.imageHeight * displayScale))
        if let old = pixelBuffer {
            if old.width == pw { return }  // no change
            // Width changed: copy columns right-aligned, drop oldest on left.
            pixelBuffer = old.resized(toWidth: pw)
        } else {
            pixelBuffer = SpectrogramPixelBuffer(width: pw, height: ph)
        }
        // Don't nil displayImage — the old frame stays visible until the next tick
        // renders from the resized buffer, avoiding a blank flash during window resize.
    }

    fileprivate func tick(link: CADisplayLink) {
        guard let buf = pixelBuffer else { return }
        let elapsed = lastTargetTimestamp == 0
            ? link.duration
            : min(link.targetTimestamp - lastTargetTimestamp, 0.2)
        lastTargetTimestamp = link.targetTimestamp
        // Accumulate in logical points so scroll speed is display-scale-independent.
        scrollAccumulator += elapsed * Self.pointsPerSecond

        // FFT frames consumed at pointsPerSecond / stripWidthPoints = 30/sec on any screen.
        // Physical columns per strip scales with displayScale.
        let physicalColumns = max(1, Int((Self.stripWidthPoints * Double(displayScale)).rounded()))
        guard scrollAccumulator >= Self.stripWidthPoints else { return }

        var didRender = false
        while scrollAccumulator >= Self.stripWidthPoints {
            let column: [Float]
            if !columnQueue.isEmpty {
                let cols = columnQueue.removeFirst()
                guard !cols.isEmpty, !cols[0].isEmpty else { scrollAccumulator -= Self.stripWidthPoints; continue }
                column = cols.count == 1
                    ? cols[0]
                    : zip(cols[0], cols[1]).map { ($0 + $1) * 0.5 }
                lastColumn = column
            } else if let last = lastColumn {
                column = last
            } else {
                scrollAccumulator = 0
                break
            }
            for _ in 0..<physicalColumns {
                buf.appendColumn(column)
            }
            scrollAccumulator -= Self.stripWidthPoints
            didRender = true
        }
        if didRender { displayImage = buf.makeImage() }
    }
}

// MARK: - Pixel buffer

private final class SpectrogramPixelBuffer {
    let width: Int
    let height: Int
    // Straight (non-premultiplied) RGBA — allows storing true white (255,255,255)
    // at any alpha without the rgb values collapsing to gray as they do in premultiplied format.
    private var pixelData: [UInt8]

    // Colormap (straight RGBA): white with a long transparency ramp up to -12 dB.
    static let colorTable: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = {
        typealias Stop = (pos: Float, r: Float, g: Float, b: Float, a: Float)
        let stops: [Stop] = [
            (0.00, 1.000, 1.000, 1.000, 0.00),  // white transparent    (-60 dB)
            (0.467, 1.000, 1.000, 1.000, 0.40),  // white 40%            (-32 dB)
            (0.70, 1.000, 1.000, 1.000, 1.00),  // white opaque         (-18 dB)
            (1.00, 1.000, 1.000, 1.000, 1.00),  // white opaque         (  0 dB)
        ]
        func map(_ v: Float) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            for i in 1..<stops.count {
                let lo = stops[i - 1], hi = stops[i]
                guard v <= hi.pos else { continue }
                let t = (v - lo.pos) / (hi.pos - lo.pos)
                func lerp(_ a: Float, _ b: Float) -> UInt8 {
                    UInt8(max(0, min(255, Int((a + t * (b - a)) * 255))))
                }
                return (r: lerp(lo.r, hi.r), g: lerp(lo.g, hi.g),
                        b: lerp(lo.b, hi.b), a: lerp(lo.a, hi.a))
            }
            return (r: 128, g: 96, b: 247, a: 255)
        }
        return (0..<256).map { map(Float($0) / 255) }
    }()

    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(width: Int, height: Int) {
        self.width  = width
        self.height = height
        // Array initialises to zero → fully transparent pixels.
        pixelData = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Returns a new buffer of the given width with this buffer's content copied right-aligned.
    /// The rightmost `min(oldWidth, newWidth)` columns are preserved; new pixels on the left are transparent.
    func resized(toWidth newWidth: Int) -> SpectrogramPixelBuffer {
        let newBuf  = SpectrogramPixelBuffer(width: newWidth, height: height)
        let copyW   = min(width, newWidth)
        let srcXOff = max(0, width    - newWidth) * 4
        let dstXOff = max(0, newWidth - width)    * 4
        pixelData.withUnsafeBytes { srcRaw in
            newBuf.pixelData.withUnsafeMutableBytes { dstRaw in
                let src = srcRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let dst = dstRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    memcpy(dst + y * newWidth * 4 + dstXOff,
                           src + y * width    * 4 + srcXOff,
                           copyW * 4)
                }
            }
        }
        return newBuf
    }

    func appendColumn(_ column: [Float]) {
        let binCount = column.count
        guard binCount > 0 else { return }

        let bytesPerRow = width * 4
        pixelData.withUnsafeMutableBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)

            // Shift every row one pixel left.
            for y in 0..<height {
                let row = ptr + y * bytesPerRow
                memmove(row, row + 4, bytesPerRow - 4)
            }

            // Paint the new rightmost column, interpolating between adjacent bins
            // to avoid hard horizontal lines at bin boundaries.
            let xOff       = (width - 1) * 4
            let colorTable  = Self.colorTable
            let binCountF   = Float(binCount - 1)
            let heightF     = Float(max(1, height - 1))
            for y in 0..<height {
                let binF  = Float(height - 1 - y) * binCountF / heightF
                let binLo = max(0, min(binCount - 2, Int(binF)))
                let t     = binF - Float(binLo)
                let val   = column[binLo] * (1 - t) + column[binLo + 1] * t
                let cIdx  = max(0, min(255, Int(val * 255)))
                let c     = colorTable[cIdx]
                let off   = y * bytesPerRow + xOff
                ptr[off]     = c.r
                ptr[off + 1] = c.g
                ptr[off + 2] = c.b
                ptr[off + 3] = c.a
            }
        }
    }

    fileprivate func makeImage() -> CGImage? {
        // Snapshot into an immutable NSData so the CGImage's provider holds a stable copy
        // while the buffer continues to be modified for the next frame.
        let snapshot = pixelData.withUnsafeBytes { raw in
            NSData(bytes: raw.baseAddress!, length: raw.count)
        }
        guard let provider = CGDataProvider(data: snapshot as CFData) else { return nil }
        return CGImage(
            width:             width,
            height:            height,
            bitsPerComponent:  8,
            bitsPerPixel:      32,
            bytesPerRow:       width * 4,
            space:             colorSpace,
            bitmapInfo:        CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider:          provider,
            decode:            nil,
            shouldInterpolate: true,
            intent:            .defaultIntent
        )
    }
}
#endif
