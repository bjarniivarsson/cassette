// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI

struct BarsSpectrumAnalyzerView: View {
    let channels: [[Float]]
    let theme: SpectrumTheme

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
                let color = index == 0 ? theme.leftColor : theme.rightColor
                ZStack {
                    SpectrumBars(magnitudes: padded, displayCount: displayCount)
                        .fill(color.opacity(opacity.fill))
                    SpectrumBars(magnitudes: padded, displayCount: displayCount)
                        .stroke(color.opacity(opacity.stroke), lineWidth: 1)
                }
                .animation(.easeOut(duration: 0.15), value: padded)
            }
        }
        .drawingGroup()
    }
}

private struct SpectrumBars: Shape {
    var magnitudes: AnimatableMagnitudes
    let displayCount: Int

    var animatableData: AnimatableMagnitudes {
        get { magnitudes }
        set { magnitudes = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = displayCount
        guard count > 0 else { return Path() }

        let gap: CGFloat = 2
        let barWidth = max(1, (rect.width - gap * CGFloat(count - 1)) / CGFloat(count))
        let h = rect.height + 1  // +1 pushes zero-height bars below the frame so they're clipped

        var path = Path()
        for i in 0..<count {
            let x = CGFloat(i) * (barWidth + gap)
            let barHeight = h * CGFloat(magnitudes.values[i])
            let y = h - barHeight
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: barWidth, height: barHeight),
                cornerSize: CGSize(width: 2, height: 2)
            )
        }
        return path
    }
}
#endif
