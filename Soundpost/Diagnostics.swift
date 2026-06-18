import Foundation
import os

/// Lightweight diagnostics for the M9 durability layer: always an `os.Logger`
/// line for the local console, plus a Sentry message for the rare/notable cases
/// worth surfacing in production (which storage rung the container landed on, an
/// unrecoverable backfill source). Messages are static / non-PII by construction
/// — never log a capsule's note, place, or audio.
enum Diagnostics {
    private static let logger = Logger(subsystem: "com.soundpost.Soundpost", category: "durability")

    /// Routine, expected progress — local log only.
    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    /// A notable, non-fatal condition. Logged locally and surfaced to Sentry
    /// (Release only) so we can see how the durability path behaves in the wild.
    static func notice(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        SentryBootstrap.capture(message: message)
    }
}
