import Foundation
import os

/// Lightweight diagnostics for the durability layer: always an `os.Logger` line for
/// the local console, plus a Sentry message for the rare/notable cases worth seeing
/// in production (which storage rung the container landed on, an unrecoverable
/// backfill source).
///
/// **The no-PII rule is enforced by the type, not by a comment.** These take
/// `StaticString`, which the compiler will only build from a literal — an
/// interpolation, a variable, or anything derived from a capsule simply does not
/// compile. Until now the guarantee was a doc comment on a `String` parameter, and
/// the audit that checked all fourteen call sites and found them clean also had to
/// note that one future interpolating call site would leak silently, with nothing
/// beneath it. M15 gave that a sharper edge: the app now holds sound labels, which
/// are inferred from someone's recording, and `CaptureView` puts one into an
/// `accessibilityLabel` — so "no dynamic string can reach Sentry" stopped being
/// obviously true and became something worth making structural.
enum Diagnostics {
    private static let logger = Logger(subsystem: "com.soundpost.Soundpost", category: "durability")

    /// Routine, expected progress — local log only.
    static func info(_ message: StaticString) {
        logger.info("\(message, privacy: .public)")
    }

    /// A notable, non-fatal condition. Logged locally and surfaced to Sentry
    /// (Release only) so we can see how the durability path behaves in the wild.
    static func notice(_ message: StaticString) {
        logger.warning("\(message, privacy: .public)")
        SentryBootstrap.capture(message: message)
    }

    /// The one shape of dynamic detail that is safe: a numeric code.
    ///
    /// `CloudSyncMonitor` wants to record *which* CloudKit error it decided not to
    /// surface, and the code is an integer from the framework — it cannot carry a
    /// note, a place, or a label. Giving that its own door means the general case
    /// stays literal-only instead of loosening to `String` for one caller, which is
    /// how a rule like this usually dies.
    static func notice(_ message: StaticString, code: Int) {
        logger.warning("\(message, privacy: .public) (code \(code, privacy: .public))")
        SentryBootstrap.capture(message: message, code: code)
    }
}
