import SwiftUI

/// Draws normalized (0...1) amplitude samples as a centered bar waveform.
/// Reused for the live recording meter (M3) and the capsule card (M4).
struct WaveformView: View {
    let samples: [Float]
    var color: Color = .accentColor
    /// When set (0...1), bars up to this fraction are full color and the rest
    /// dimmed — used to show playback progress.
    var progress: Double? = nil
    var barSpacing: CGFloat = 2
    var minBarHeight: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let count = samples.count
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = max(1, (size.width - totalSpacing) / CGFloat(count))
            let midY = size.height / 2

            for (index, sample) in samples.enumerated() {
                let height = max(minBarHeight, CGFloat(sample) * size.height)
                let x = CGFloat(index) * (barWidth + barSpacing)
                let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                let fillColor: Color
                if let progress {
                    let played = Double(index) / Double(count) <= progress
                    fillColor = played ? color : color.opacity(0.25)
                } else {
                    fillColor = color
                }
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(fillColor))
            }
        }
        .animation(.linear(duration: 0.08), value: samples)
    }
}

#Preview {
    WaveformView(samples: (0..<48).map { _ in Float.random(in: 0.1...1) })
        .frame(height: 120)
        .padding()
}
