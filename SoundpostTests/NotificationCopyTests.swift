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

    private func digest(
        note: String? = nil,
        place: String? = nil,
        created: Date = .now,
        soundprint: Soundprint? = nil
    ) -> NotificationCopy.Digest {
        NotificationCopy.Digest(createdAt: created, note: note, placeName: place, mood: .calm, soundprint: soundprint)
    }

    /// A confident single-label soundprint, in the stored provenance form.
    private func heard(_ identifier: String, _ confidence: Double = 0.82) -> Soundprint {
        Soundprint(classifier: "version1", labels: [.init(identifier: identifier, confidence: confidence)])
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

    // MARK: What it heard — the last-resort lead (M15 §S5)

    /// **This test used to assert the defect.** It pinned
    /// «"rain" — tap to listen.» as correct, which is why a green suite never noticed
    /// that a classifier label was being dressed as the user's own sentence on a lock
    /// screen (§4A rule 1; found by Codex in the M17 review). The gap the classifier
    /// fills is still filled — it is now attributed instead of quoted.
    @Test func personalizedSealFallsBackToWhatItHeardWithoutWords() {
        // No note, no place, but something was heard: the gap the classifier fills.
        let (_, body) = seal(digest(soundprint: heard("rain")), personalized: true)
        let phrase = SoundVocabulary.displayName(for: "rain")
        #expect(phrase != nil)
        #expect(body == String(localized: "Soundpost heard \(phrase!) — tap to listen."))
        #expect(!body.contains("“"), "never dressed as the user's own words")
    }

    @Test func theUsersOwnWordsAlwaysOutrankWhatItHeard() {
        let (_, body) = seal(digest(note: "Rain on the window", soundprint: heard("rain")), personalized: true)
        #expect(body == String(localized: "“\("Rain on the window")” — tap to listen."))
    }

    @Test func genericCopyNeverLeaksASoundLabel() {
        // Opted out of personalized copy: a label must not reach the lock screen
        // even though one is stored on the capsule.
        let (_, body) = seal(digest(soundprint: heard("rain")), personalized: false)
        #expect(body == String(localized: "Open Soundpost to hear this moment again."))
        if let phrase = SoundVocabulary.displayName(for: "rain") {
            #expect(!body.contains(phrase))
        }
    }

    // MARK: Content-version token gates the request identity

    @Test func contentVersionDiffersByPreference() {
        #expect(NotificationPreferences.contentVersion(personalized: true, listening: true)
                != NotificationPreferences.contentVersion(personalized: false, listening: true))
    }

    /// Withdrawing listening consent has to invalidate already-scheduled bodies:
    /// a sound phrase may already be baked into a pending request, and the
    /// scheduler skips identifiers it has already scheduled. Without this the
    /// label would keep firing after the switch was turned off — the behaviour the
    /// Settings copy and the 1.6.0 release notes promise by name.
    @Test func contentVersionDiffersByListeningWhilePersonalized() {
        #expect(NotificationPreferences.contentVersion(personalized: true, listening: true)
                != NotificationPreferences.contentVersion(personalized: true, listening: false))
    }

    @Test func contentVersionIgnoresListeningWhenCopyIsGeneric() {
        // Generic copy never consults a digest, so listening cannot change the body
        // and must not churn every scheduled request.
        #expect(NotificationPreferences.contentVersion(personalized: false, listening: true)
                == NotificationPreferences.contentVersion(personalized: false, listening: false))
    }
}
