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
    /// Purely visual instances (live meter, card previews) are hidden from
    /// VoiceOver; the surrounding view conveys the meaning.
    var isDecorative: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let count = samples.count
            // The bar math lives in `WaveformGeometry` so this view and the video
            // renderer draw the same waveform (M13 §4B) — identical arithmetic,
            // one place to change it.
            let geometry = WaveformGeometry(barSpacing: barSpacing, minBarHeight: minBarHeight)

            for (index, bar) in geometry.bars(for: samples, in: size).enumerated() {
                let fillColor: Color
                if let progress {
                    let played = WaveformGeometry.isPlayed(index: index, count: count, progress: progress)
                    fillColor = played ? color : color.opacity(0.25)
                } else {
                    fillColor = color
                }
                context.fill(Path(roundedRect: bar.rect, cornerRadius: bar.cornerRadius), with: .color(fillColor))
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: samples)
        .accessibilityElement()
        .accessibilityHidden(isDecorative)
        .accessibilityLabel(Text("Sound waveform"))
        .accessibilityValue(progress == nil ? Text("") : Text("\(Int(((progress ?? 0) * 100).rounded())) percent played"))
    }
}

#Preview {
    WaveformView(samples: (0..<48).map { _ in Float.random(in: 0.1...1) })
        .frame(height: 120)
        .padding()
}
