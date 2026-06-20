import Foundation

/// Pure, system-free helpers for turning a raw APNs device token into the shape
/// the delivery backend stores. Kept dependency-free so the whole token-shaping
/// seam is unit-testable without a real APNs-enabled device (mirrors the reused
/// `cli pulse:CLIPulseCore/PushTokenSync.swift`).
enum PushTokenSync {
    /// Lowercase-hex encode the raw token handed to
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` — the
    /// form APNs HTTP/2 endpoints expect in the `/3/device/<token>` URL path.
    static func formatToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// APNs tokens are typically 64 hex chars (32 bytes). Bound-check before we
    /// ever send one to the server (matches the server-side length CHECK in §E).
    static func isValidTokenLength(_ hexToken: String) -> Bool {
        hexToken.count >= 8 && hexToken.count <= 256
    }

    /// The only platform Soundpost ships. Stored on the `device_tokens` row.
    static let platform = "ios"
}

/// Which APNs environment this *build* is bound to. The resolved value of the
/// `aps-environment` entitlement is **not readable at runtime**, so we infer it
/// from the build configuration: Xcode Debug → APNs sandbox; TestFlight + App
/// Store (both Release) → production (docs/M10-DEVPLAN.md §4F). The poller picks
/// the matching APNs host per token, so a dev token never gets pushed to the
/// production host (and vice versa).
enum DeliveryEnvironment {
    /// `"development"` under a Debug build, `"production"` otherwise.
    static var current: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
}
