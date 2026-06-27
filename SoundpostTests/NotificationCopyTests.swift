import Testing
import Foundation
@testable import Soundpost

/// The notification copy-builder (§S3/§4A): generic by default, personalized only
/// when opted in, and always metadata-only. Comparisons go through the same
/// `String(localized:)` calls as the builder, so the suite is locale-independent.
@Suite
struct NotificationCopyTests {
    private func seal(_ digest: NotificationCopy.Digest?, personalized: Bool) -> (title: String, body: String) {
        let item = PlannedNotification(capsuleID: UUID(), fireDate: .now, timeZoneID: nil, kind: .seal)
        return NotificationCopy.make(for: item, digest: digest, personalized: personalized)
    }

    private func echo(created: Date, fire: Date, _ digest: NotificationCopy.Digest?, personalized: Bool) -> (title: String, body: String) {
        let item = PlannedNotification(capsuleID: UUID(), fireDate: fire, timeZoneID: nil, kind: .echo)
        return NotificationCopy.make(for: item, digest: digest, personalized: personalized)
    }

    private func digest(note: String? = nil, place: String? = nil, created: Date = .now) -> NotificationCopy.Digest {
        NotificationCopy.Digest(createdAt: created, note: note, placeName: place, mood: .calm)
    }

    // MARK: Generic (default, opt-out)

    @Test func genericSealIsTheCalmDefault() {
        let (title, body) = seal(digest(note: "Rain on the window"), personalized: false)
        #expect(title == String(localized: "A capsule has resurfaced"))
        #expect(body == String(localized: "Open Soundpost to hear this moment again."))
        #expect(!body.contains("Rain on the window")) // private words never leak when off
    }

    @Test func genericEchoCountsDaysSinceCapture() {
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let fire = created.addingTimeInterval(10 * 86_400)
        let (title, body) = echo(created: created, fire: fire, digest(created: created), personalized: false)
        #expect(title == String(localized: "An echo from your past"))
        #expect(body == String(localized: "\(10) days ago, you captured this sound. Listen back."))
    }

    // MARK: Personalized (opt-in)

    @Test func personalizedSealLeadsWithTheUsersOneLine() {
        let (_, body) = seal(digest(note: "Rain on the window"), personalized: true)
        #expect(body == String(localized: "“\("Rain on the window")” — tap to listen."))
        #expect(body != String(localized: "Open Soundpost to hear this moment again."))
    }

    @Test func personalizedSealLeadsWithPlaceWhenNoNote() {
        let (_, body) = seal(digest(note: nil, place: "Shibuya Station"), personalized: true)
        #expect(body == String(localized: "“\("Shibuya Station")” — tap to listen."))
    }

    @Test func personalizedSealFallsBackToGenericWithoutWords() {
        // Opted in, but nothing to lead with → never render an empty quote.
        let (_, body) = seal(digest(note: "   ", place: nil), personalized: true)
        #expect(body == String(localized: "Open Soundpost to hear this moment again."))
    }

    @Test func personalizedEchoLeadsWithWordsAndKeepsTheCount() {
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let fire = created.addingTimeInterval(14 * 86_400)
        let (_, body) = echo(created: created, fire: fire, digest(note: "morning birds", created: created), personalized: true)
        #expect(body == String(localized: "“\("morning birds")” — \(14) days ago. Listen back."))
    }

    // MARK: Content-version token gates the request identity

    @Test func contentVersionDiffersByPreference() {
        #expect(NotificationPreferences.contentVersion(personalized: true)
                != NotificationPreferences.contentVersion(personalized: false))
    }
}
