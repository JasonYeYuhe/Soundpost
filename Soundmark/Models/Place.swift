import Foundation

/// A lightweight, Codable location stamp for a capsule.
///
/// Stored inline on the `Capsule` model. Location is optional and
/// permission-gated (see docs/PROJECT.md), so a capsule can exist without one.
/// The reverse-geocoded `name` is filled in during the capture flow (M3).
struct Place: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Human-readable name, e.g. "Ueno Park". Optional until geocoded.
    var name: String?

    init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }
}
