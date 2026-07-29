import Testing
import CoreGraphics
import Foundation
@testable import Soundpost

/// The one waveform math shared by the on-screen `Canvas` and the exported video
/// (M13 §4B). If these drift, the video stops matching what the user saw.
struct WaveformGeometryTests {
    private let geometry = WaveformGeometry()      // the view's defaults: spacing 2, floor 2
    private let size = CGSize(width: 100, height: 40)

    // MARK: - Bar layout

    @Test func barsAreCenteredOnTheMidLine() {
        let bars = geometry.bars(for: [1.0, 0.5], in: size)
        #expect(bars.count == 2)
        for bar in bars {
            #expect(abs(bar.rect.midY - size.height / 2) < 0.0001)
        }
    }

    @Test func barWidthFillsTheSpaceLeftBySpacing() {
        // 4 bars over 100 wide with 3 × 2 spacing → (100 − 6) / 4 = 23.5 each.
        #expect(geometry.barWidth(count: 4, width: 100) == 23.5)
        // The first bar starts flush left; the last ends flush right.
        let bars = geometry.bars(for: [0.5, 0.5, 0.5, 0.5], in: size)
        #expect(bars.first?.rect.minX == 0)
        #expect(abs((bars.last?.rect.maxX ?? 0) - 100) < 0.0001)
    }

    @Test func barHeightScalesWithTheSampleAndHonoursTheFloor() {
        let bars = geometry.bars(for: [1.0, 0.5, 0.0], in: size)
        #expect(bars[0].rect.height == 40)          // full-scale sample
        #expect(bars[1].rect.height == 20)          // half
        #expect(bars[2].rect.height == 2)           // silence still shows a sliver
    }

    @Test func barWidthNeverCollapsesBelowOnePoint() {
        // Denser than the space allows: the width clamps instead of going negative,
        // so a long waveform still draws something rather than nothing.
        #expect(geometry.barWidth(count: 500, width: 100) == 1)
        #expect(geometry.bars(for: Array(repeating: 0.5, count: 500), in: size).allSatisfy { $0.rect.width == 1 })
    }

    @Test func cornerRadiusRoundsTheBarCaps() {
        let bars = geometry.bars(for: [1.0, 1.0], in: size)
        #expect(bars[0].cornerRadius == bars[0].rect.width / 2)
    }

    @Test func emptySamplesProduceNoBars() {
        #expect(geometry.bars(for: [], in: size).isEmpty)
        #expect(geometry.barWidth(count: 0, width: 100) == 0)
    }

    @Test func scaledSpacingStillTilesLeftToRight() {
        // The video canvas scales spacing up (§4C); bars must still tile in order
        // with no overlap, whatever the units.
        let video = WaveformGeometry(barSpacing: 6, minBarHeight: 9)
        let bars = video.bars(for: Array(repeating: Float(0.6), count: 48),
                             in: CGSize(width: 907, height: 163))
        #expect(bars.count == 48)
        for (previous, next) in zip(bars, bars.dropFirst()) {
            #expect(next.rect.minX >= previous.rect.maxX)
            #expect(abs(next.rect.minX - (previous.rect.maxX + 6)) < 0.0001)
        }
        #expect((bars.last?.rect.maxX ?? 0) <= 907.0001)
    }

    // MARK: - Playback-position reveal

    @Test func revealIsAPlaybackPositionSweepNotAnAmplitudeTest() {
        // Bar 0 is played the instant playback starts; the last only at the end.
        #expect(WaveformGeometry.isPlayed(index: 0, count: 4, progress: 0))
        #expect(!WaveformGeometry.isPlayed(index: 1, count: 4, progress: 0))
        #expect(WaveformGeometry.isPlayed(index: 1, count: 4, progress: 0.25))
        #expect(WaveformGeometry.isPlayed(index: 3, count: 4, progress: 0.75))
        #expect(WaveformGeometry.isPlayed(index: 3, count: 4, progress: 1))
    }

    @Test func revealOnlyEverGrows() {
        // Monotonic in progress: a bar that has lit up never goes dark again — the
        // property S2's frame test asserts against the real exported video.
        let count = 20
        var previousLit = -1
        for step in 0...20 {
            let progress = Double(step) / 20
            let lit = (0..<count).filter { WaveformGeometry.isPlayed(index: $0, count: count, progress: progress) }.count
            #expect(lit >= previousLit)
            previousLit = lit
        }
        #expect(previousLit == count)
    }

    @Test func revealIsSafeAtZeroCount() {
        #expect(!WaveformGeometry.isPlayed(index: 0, count: 0, progress: 1))
    }

    // MARK: - Core Graphics safety

    @Test func cornerRadiusIsClampedForShortBars() {
        // A wide-but-short bar's natural radius (width/2) exceeds half its height.
        // `CGPath(roundedRect:)` requires the corner to fit in both axes — SwiftUI
        // clamps silently, so the video path must clamp identically.
        let short = WaveformGeometry.Bar(
            rect: CGRect(x: 0, y: 0, width: 20, height: 4),
            cornerRadius: 10
        )
        #expect(WaveformGeometry.clampedCornerRadius(short) == 2)

        let tall = WaveformGeometry.Bar(
            rect: CGRect(x: 0, y: 0, width: 20, height: 40),
            cornerRadius: 10
        )
        #expect(WaveformGeometry.clampedCornerRadius(tall) == 10)
    }
}
