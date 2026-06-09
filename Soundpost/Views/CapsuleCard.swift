import SwiftUI
import UIKit

/// A capsule as a tappable, glanceable keepsake: a mood-tinted waveform with its
/// one line, place, and date. Sealed capsules render locked (honest copy) until
/// their date. This is the app's signature object (docs/PROJECT.md differentiation).
struct CapsuleCard: View {
    let capsule: Capsule

    private var tint: Color { capsule.mood?.tint ?? .accentColor }
    private var isLocked: Bool { capsule.state == .sealed && !capsule.isContentVisible() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isLocked { lockedBody } else { openBody }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(tint.opacity(0.15), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: capsule.mood?.symbolName ?? "waveform")
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(capsule.mood?.label ?? String(localized: "Sound"))
                    .font(.subheadline.weight(.semibold))
                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusGlyph
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch capsule.state {
        case .sealed: Image(systemName: "lock.fill").foregroundStyle(.secondary)
        case .resurfaced: Image(systemName: "sparkles").foregroundStyle(tint)
        default: EmptyView()
        }
    }

    private var openBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            WaveformView(samples: capsule.waveformSamples, color: tint)
                .frame(height: 56)
            if let note = capsule.note, !note.isEmpty {
                Text(note).font(.body).lineLimit(2)
            }
            HStack(spacing: 12) {
                Label(durationString, systemImage: "play.circle")
                if let place = capsule.place?.name {
                    Label(place, systemImage: "mappin").lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A flattened, dimmed hint of the waveform — present but not revealed.
            WaveformView(samples: capsule.waveformSamples.map { min($0, 0.25) }, color: .secondary)
                .frame(height: 28)
                .opacity(0.5)
            if let until = capsule.sealUntil {
                Text("Opens \(until.formatted(.dateTime.month().day().year()))")
                    .font(.subheadline.weight(.medium))
            }
            Text("A gentle seal — held until then.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(capsule.createdAt) {
            return capsule.createdAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(capsule.createdAt) { return String(localized: "Yesterday") }
        return capsule.createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var durationString: String {
        let total = Int(capsule.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
