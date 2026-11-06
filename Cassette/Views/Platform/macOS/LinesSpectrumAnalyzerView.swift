// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI

struct LinesSpectrumAnalyzerView: View {
    @Environment(\.appContainer) private var container
    private var channels: [[Float]] { container?.spectrumAnalyzer.channels ?? [] }

    // Opacity pair (fill, stroke) per channel index — channel 1 is slightly more transparent
    // so the two curves are readable when stacked.
    private static let layerOpacity: [(fill: Double, stroke: Double)] = [
        (0.50, 0.90),
        (0.30, 0.75),
    ]

    var body: some View {
        ZStack {
            ForEach(0..<min(channels.count, 2), id: \.self) { index in
                let opacity = Self.layerOpacity[index]
                let magnitudes = channels[index]
                let displayCount = magnitudes.count
                let padded = AnimatableMagnitudes(magnitudes)
                let color = Color.white
                ZStack {
                    SpectrumCurve(magnitudes: padded, displayCount: displayCount, closed: true)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(opacity.fill), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    SpectrumCurve(magnitudes: padded, displayCount: displayCount, closed: false)
                        .stroke(color.opacity(opacity.stroke), lineWidth: 1.5)
                }
                .animation(.easeOut(duration: 0.15), value: padded)
            }
        }
        .drawingGroup()
    }
}

private struct SpectrumCurve: Shape {
    var magnitudes: AnimatableMagnitudes
    let displayCount: Int
    let closed: Bool

    var animatableData: AnimatableMagnitudes {
        get { magnitudes }
        set { magnitudes = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = displayCount
        guard count > 1 else { return Path() }

        let w = rect.width, h = rect.height + 1  // +1 pushes the flat baseline below the frame so it's clipped
        let step = w / CGFloat(count - 1)

        var path = Path()
        path.move(to: CGPoint(x: 0, y: h * (1 - CGFloat(magnitudes.values[0]))))
        for i in 1..<count - 1 {
            let xi = step * CGFloat(i),     yi = h * (1 - CGFloat(magnitudes.values[i]))
            let xn = step * CGFloat(i + 1), yn = h * (1 - CGFloat(magnitudes.values[i + 1]))
            path.addQuadCurve(
                to: CGPoint(x: (xi + xn) / 2, y: (yi + yn) / 2),
                control: CGPoint(x: xi, y: yi)
            )
        }
        path.addLine(to: CGPoint(x: w, y: h * (1 - CGFloat(magnitudes.values[count - 1]))))

        if closed {
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.closeSubpath()
        }
        return path
    }
}

// Fixed-size (maxBinCount) VectorArithmetic wrapper so SwiftUI can interpolate
// magnitude arrays regardless of the active bin count. Shorter arrays are zero-padded
// to maxBinCount so zip never truncates — switching detail levels animates correctly
// in both directions.
struct AnimatableMagnitudes: VectorArithmetic, Equatable {
    static let maxBinCount = 40
    var values: [Float]  // always maxBinCount elements

    init(_ source: [Float]) {
        if source.count >= Self.maxBinCount {
            values = Array(source.prefix(Self.maxBinCount))
        } else {
            values = source + Array(repeating: 0, count: Self.maxBinCount - source.count)
        }
    }

    private init(raw: [Float]) { values = raw }

    static var zero: Self { Self(raw: Array(repeating: 0, count: maxBinCount)) }

    static func + (lhs: Self, rhs: Self) -> Self { Self(raw: zip(lhs.values, rhs.values).map(+)) }
    static func - (lhs: Self, rhs: Self) -> Self { Self(raw: zip(lhs.values, rhs.values).map(-)) }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * Float(rhs) }
    }

    var magnitudeSquared: Double {
        Double(values.reduce(into: Float(0)) { $0 += $1 * $1 })
    }
}
#endif
