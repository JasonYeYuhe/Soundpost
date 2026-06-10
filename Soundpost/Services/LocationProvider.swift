import Foundation
import CoreLocation

/// One-shot location + reverse-geocode for tagging a capsule with a place.
/// Optional and permission-gated (docs/PROJECT.md): if the user declines or no
/// fix is available, `requestPlace()` simply returns nil — never blocks capture.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Prompt for when-in-use authorization (used by onboarding to ask up front,
    /// with context). Returns whether location is now authorized. No-op if the
    /// user has already decided.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let status = await ensureAuthorized()
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Resolve the current place, or nil if unavailable/denied.
    func requestPlace() async -> Place? {
        let status = await ensureAuthorized()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        guard let location = await requestOneLocation() else { return nil }
        let name = await reverseGeocode(location)
        return Place(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            name: name
        )
    }

    private func ensureAuthorized() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            authContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private func requestOneLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return nil }
        return placemark.name ?? placemark.locality ?? placemark.administrativeArea
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let continuation = authContinuation else { return }
            authContinuation = nil
            continuation.resume(returning: status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in
            guard let continuation = locationContinuation else { return }
            locationContinuation = nil
            continuation.resume(returning: last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard let continuation = locationContinuation else { return }
            locationContinuation = nil
            continuation.resume(returning: nil)
        }
    }
}
