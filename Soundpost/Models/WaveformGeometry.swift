import CoreGraphics

/// The single source of truth for how normalized amplitude samples become bars.
///
/// Extracted from `WaveformView` (M13 §4B) so the waveform drawn **on screen**
/// and the one burned into an **exported video** are computed by the same math
/// and cannot drift. Pure, `Sendable`, and unit-tested: it knows nothing about
/// SwiftUI or Core Graphics — it only answers "which rectangles, where".
///
/// Coordinates are **top-left origin, y-down** (`y` grows downward), matching
/// SwiftUI's `Canvas`. The video renderer sets up an explicitly top-left
/// `CGContext` for exactly this reason (§4A), so one set of rects serves both.
struct WaveformGeometry: Equatable, Sendable {
    /// Gap between adjacent bars, in the target space's units.
    var barSpacing: CGFloat = 2
    /// Floor so a near-silent sample still shows a sliver of bar.
    var minBarHeight: CGFloat = 2

    init(barSpacing: CGFloat = 2, minBarHeight: CGFloat = 2) {
        self.barSpacing = barSpacing
        self.minBarHeight = minBarHeight
    }

    /// One bar: where it sits and how round its caps are.
    struct Bar: Equatable, Sendable {
        let rect: CGRect
        let cornerRadius: CGFloat
    }

    /// Width of each of `count` bars laid across `width`, including the spacing
    /// between them. At least 1 unit wide so a dense waveform still draws.
    func barWidth(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let totalSpacing = barSpacing * CGFloat(count - 1)
        return max(1, (width - totalSpacing) / CGFloat(count))
    }

    /// The bars for `samples` laid out in `size`, each centered on the mid-line.
    func bars(for samples: [Float], in size: CGSize) -> [Bar] {
        guard !samples.isEmpty else { return [] }
        let width = barWidth(count: samples.count, width: size.width)
        let midY = size.height / 2
        return samples.enumerated().map { index, sample in
            let height = max(minBarHeight, CGFloat(sample) * size.height)
            let x = CGFloat(index) * (width + barSpacing)
            return Bar(
                rect: CGRect(x: x, y: midY - height / 2, width: width, height: height),
                cornerRadius: width / 2
            )
        }
    }

    /// Whether the bar at `index` of `count` sits behind the playhead.
    ///
    /// This is **playback-position** sync (§4B) — the bar lights up because the
    /// playhead has passed it, *not* because of anything about the audio at that
    /// instant. It is deliberately not amplitude or transient sync, and the copy
    /// around it should never imply otherwise.
    static func isPlayed(index: Int, count: Int, progress: Double) -> Bool {
        guard count > 0 else { return false }
        return Double(index) / Double(count) <= progress
    }

    /// A corner radius safe for Core Graphics' rounded-rect path, which requires
    /// the corner size to be at most half the rect in each axis. SwiftUI's
    /// `Path(roundedRect:cornerRadius:)` clamps this for us; `CGPath` does not, so
    /// the video renderer clamps here to stay pixel-consistent with the view.
    static func clampedCornerRadius(_ bar: Bar) -> CGFloat {
        min(bar.cornerRadius, bar.rect.width / 2, bar.rect.height / 2)
    }
}
