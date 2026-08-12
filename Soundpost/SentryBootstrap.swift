import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Crash + app-hang reporting ONLY — no performance tracing, no screenshots /
/// view-hierarchy, no PII, and request data is stripped so no user content (the
/// one-line note, place name, audio paths) can leave the device.
///
/// Only active in **Release** builds (TestFlight / App Store): DEBUG runs and the
/// unit-test host never initialize it, so the Sentry dashboard stays free of
/// dev-loop noise. In a build that does not link sentry-cocoa, `canImport(Sentry)`
/// is false and `start()` compiles to an empty no-op.
///
/// Privacy: this collects "Crash Data" / "Other Diagnostic Data" sent to a third
/// party — declared in PrivacyInfo.xcprivacy and the App Store privacy label as
/// *not linked to identity* and *not used for tracking*. Keep those in lockstep.
enum SentryBootstrap {
    /// Public Sentry client key (DSN). DSNs are designed to be embedded in the
    /// client and shipped — not a secret.
    private static let dsn =
        "https://b8ce33d9b5e88f1f04c08a5fd596ce65@o4511263220891648.ingest.us.sentry.io/4511535166980096"

    static func start() {
        #if canImport(Sentry) && !DEBUG
        SentrySDK.start { options in
            options.dsn = dsn
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.tracesSampleRate = 0.0          // crash/hang only, no perf tracing
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.sendDefaultPii = false
            options.beforeSend = { event in
                event.request = nil                 // strip any URLs / headers / bodies
                return event
            }
        }
        #endif
    }

    /// Surface a notable, non-fatal condition (a durability fallback rung, an
    /// unrecoverable backfill source) as a Sentry message. No-op in DEBUG / under
    /// tests / when sentry-cocoa isn't linked.
    ///
    /// `StaticString`, not `String`: the compiler will only build one from a literal,
    /// so a capsule's note, place or sound label cannot reach here by accident. This
    /// used to be a sentence in a doc comment asking callers to be careful, which is
    /// a guarantee only for as long as everyone reads it.
    static func capture(message: StaticString) {
        #if canImport(Sentry) && !DEBUG
        SentrySDK.capture(message: "\(message)")
        #endif
    }

    /// The numeric-detail variant. An `Int` from a framework error cannot carry user
    /// content, so this is the one place dynamic detail is allowed through — kept
    /// narrow on purpose rather than widening `capture` to `String`.
    static func capture(message: StaticString, code: Int) {
        #if canImport(Sentry) && !DEBUG
        SentrySDK.capture(message: "\(message) (code \(code))")
        #endif
    }
}
