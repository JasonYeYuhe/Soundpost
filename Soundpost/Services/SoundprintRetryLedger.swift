import Foundation

/// How many times **this device** has failed to listen to a capsule's clip (M20 §4D).
///
/// A failure leaves `soundprintRaw` nil so a later launch can try again — but nothing
/// bounded that, so a corrupt clip was re-read on every launch forever. This caps it.
///
/// **Outside the schema, and device-local, on purpose.** "Could not listen on this
/// device" is not a fact about the recording: another device may read it fine, and
/// `soundprintRaw` syncs. So a capped capsule stays `nil` — never the empty marker,
/// which means "analysed, nothing to say" (`Capsule.soundprintRaw`), is exported as
/// `soundsHeard: []`, and would turn one device's local trouble into an account-wide
/// verdict. Keyed by `Capsule.id`; removed when the capsule is written.
///
/// Counts one try per capsule per backfill run, so three launches, not one busy one.
/// Emptied whenever listening is switched off (`SoundprintEraser.eraseAll`), so
/// switching it back on is a real retry — the eraser's promise that a `nil` capsule is
/// picked up again "if the user changes their mind" holds for capped ones too.
///
/// **A file excluded from backup, not `UserDefaults`** (M20 release review). Preferences
/// travel with an iCloud or Finder backup and with Quick Start, so a new phone inherited
/// the old one's caps and never tried clips it might well read. A file in Application
/// Support marked `isExcludedFromBackup` stays on the device that wrote it.
struct SoundprintRetryLedger: Sendable {
    /// Tries before a capsule is left alone on this device.
    static let cap = 3

    static let fileName = "soundprint-retry-ledger.json"

    /// Where the counts live. Tests pass a directory of their own.
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    private var counts: [String: Int] {
        get {
            guard let data = try? Data(contentsOf: fileURL) else { return [:] }
            return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        }
        nonmutating set {
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(newValue),
                  (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
            // Set after every write: an atomic write replaces the file, and a replaced
            // file does not keep the old one's resource values.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try? url.setResourceValues(values)
        }
    }

    func attempts(for id: UUID) -> Int { counts[id.uuidString] ?? 0 }

    /// Capsules this device has given up on — left out of the backfill's fetch, so they
    /// cannot fill every batch and starve the older capsules behind them.
    var capped: Set<UUID> {
        Set(counts.filter { $0.value >= Self.cap }.keys.compactMap(UUID.init(uuidString:)))
    }

    func recordFailures(_ ids: some Sequence<UUID>) {
        var updated = counts
        for id in ids { updated[id.uuidString, default: 0] += 1 }
        counts = updated
    }

    func clear(_ ids: some Sequence<UUID>) {
        var updated = counts
        for id in ids { updated[id.uuidString] = nil }
        counts = updated
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
