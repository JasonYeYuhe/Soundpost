import SwiftUI

/// A dedicated, self-contained **share card** for export (M11 §4G) — composed
/// from the same waveform + mood / place / note pieces as `CapsuleCard`, but not a
/// pixel-copy: it's a standalone keepsake image meant to read well anywhere it's
/// shared.
///
/// Colors are **deterministic** (explicit, not semantic) so the rasterized image
/// is legible regardless of the device's light/dark setting at render time. It
/// shows only what the user already sees on the capsule — no hidden fields
/// (M11 §7 export-leak mitigation).
struct ShareCardView: View {
    let capsule: Capsule

    private var tint: Color { capsule.mood?.tint ?? .accentColor }
    // Fixed inks (scheme-independent) over a near-white card.
    private let ink = Color(white: 0.12)
    private let inkSecondary = Color(white: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.20)).frame(width: 44, height: 44)
                    Image(systemName: capsule.mood?.symbolName ?? "waveform")
                        .font(.title3)
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(capsule.mood?.label ?? String(localized: "Sound"))
                        .font(.headline).foregroundStyle(ink)
                    Text(capsule.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(inkSecondary)
                }
                Spacer(minLength: 0)
            }

            WaveformView(samples: capsule.waveformSamples, color: tint, isDecorative: true)
                .frame(height: 72)

            if let note = capsule.note, !note.isEmpty {
                Text(note)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Label(durationString, systemImage: "play.circle")
                if let place = capsule.place?.name {
                    Label(place, systemImage: "mappin").lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(inkSecondary)

            Divider().overlay(tint.opacity(0.25))

            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(tint)
                Text("Made with Soundpost")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(inkSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .background {
            LinearGradient(colors: [Color.white, tint.opacity(0.12)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var durationString: String {
        let total = Int(capsule.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
