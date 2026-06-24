import SwiftUI
import UIKit

/// Produces the two share artifacts for a capsule (M11 §4G): a rendered **card
/// image** and the **audio clip** as a temp `.m4a`. Both are the user's own data,
/// leaving only by their explicit share action; nothing beyond what the share
/// card already shows is included (M11 §7).
///
/// Gating lives in the view (`ProGate.canExport`); this type is pure and is only
/// ever reached for a **visible** capsule — the locked detail view hosts no export
/// affordance, so a sealed-not-due capsule can't be exported (M11 §4G).
enum CapsuleExporter {
    /// Render the dedicated share card to a UIImage at ~@3x (PNG-ready). No deps —
    /// SwiftUI `ImageRenderer` over `ShareCardView`. MainActor-bound.
    @MainActor
    static func cardImage(for capsule: Capsule, scale: CGFloat = 3) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCardView(capsule: capsule))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Write the capsule's audio to a temp `.m4a` for the share sheet, returning
    /// its URL — or `nil` if the capsule has no audio. Prefers the canonical
    /// `audioData`; falls back to the legacy on-disk file (pre-backfill capsules).
    static func audioFileURL(for capsule: Capsule, audioStore: AudioStore = AudioStore()) throws -> URL? {
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "Soundpost-\(dateStamp(capsule.createdAt)).m4a", directoryHint: .notDirectory)
        if let data = capsule.audioData {
            try data.write(to: dest, options: .atomic)
            return dest
        }
        if let name = capsule.audioFileName, audioStore.fileExists(name) {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: audioStore.url(for: name), to: dest)
            return dest
        }
        return nil
    }

    /// Build the full share payload (card image + audio) for a capsule. Returns
    /// `nil` only if neither artifact could be produced.
    @MainActor
    static func payload(for capsule: Capsule) -> SharePayload? {
        var items: [Any] = []
        if let image = cardImage(for: capsule) { items.append(image) }
        if let audio = try? audioFileURL(for: capsule) { items.append(audio) }
        return items.isEmpty ? nil : SharePayload(items: items)
    }

    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// Identifiable wrapper so the share sheet can be presented via `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Thin SwiftUI bridge to `UIActivityViewController` (the system share sheet).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
