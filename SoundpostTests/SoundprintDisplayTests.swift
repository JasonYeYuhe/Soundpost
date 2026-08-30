import Testing
import Foundation
@testable import Soundpost

/// M17 §S2 / §4A — *which* phrases a capsule shows, given its soundprint, its
/// visibility, its note and consent.
///
/// With per-label correction cut (§4B), these rules are the only thing standing
/// between "Soundpost heard rain" and the app asserting, permanently and in someone's
/// own gallery, that their memory was rain. So they are a pure function and they are
/// tested as one.
///
/// **This suite claims no UI coverage.** There is no UI-test target in this project.
/// What is asserted here is the policy every surface reads; that the detail view and
/// the card actually read it, and how they look, was checked by hand in the simulator.
@MainActor
struct SoundprintDisplayTests {

    private func rainy(note: String? = nil,
                       labels: [(String, Double)] = [("rain", 0.91)]) throws -> Capsule {
        let capsule = Capsule()
        try capsule.transition(to: .recording)
        try capsule.transition(to: .captured)
        capsule.note = note
        capsule.soundprintRaw = Soundprint(
            classifier: "version1",
            labels: labels.map { Soundprint.Label(identifier: $0.0, confidence: $0.1) }
        ).stored
        return capsule
    }

    private var rainPhrase: String {
        SoundVocabulary.displayName(for: "rain") ?? "rain"
    }

    // MARK: Consent

    /// The window this gate exists for is not hypothetical: the erase that normally
    /// removes these labels can lag or fail, and the app ships copy saying so. Until
    /// it catches up, a rendering path without this check puts what Soundpost heard on
    /// screen on a device where the user said stop.
    @Test func nothingIsShownWithListeningOff() throws {
        let capsule = try rainy()
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: false).isEmpty)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .card, rejecting: .none, listening: false).isEmpty)
    }

    @Test func thePhrasesAreShownWithListeningOn() throws {
        let capsule = try rainy()
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: true) == [rainPhrase])
        #expect(SoundprintDisplay.phrases(for: capsule, on: .card, rejecting: .none, listening: true) == [rainPhrase])
    }

    // MARK: Visibility

    /// A sealed capsule's sound is as hidden as its words. The same
    /// `isContentVisible(now:)` the card body, the search index and playback use.
    @Test func aSealedNotDueCapsuleShowsNothing() throws {
        let capsule = try rainy()
        capsule.sealUntil = Date.now.addingTimeInterval(86_400)
        try capsule.transition(to: .sealed)

        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: true).isEmpty)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .card, rejecting: .none, listening: true).isEmpty)
    }

    @Test func aSealedCapsulePastItsDateShowsAgain() throws {
        let capsule = try rainy()
        capsule.sealUntil = Date.now.addingTimeInterval(-86_400)
        try capsule.transition(to: .sealed)

        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: true) == [rainPhrase])
    }

    /// The clock is a parameter, so "not due" and "due" are the same capsule seen from
    /// two moments rather than two capsules built to differ.
    @Test func theSealIsJudgedAgainstTheGivenMoment() throws {
        let capsule = try rainy()
        let opensAt = Date.now.addingTimeInterval(3_600)
        capsule.sealUntil = opensAt
        try capsule.transition(to: .sealed)

        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none,
                                          now: opensAt.addingTimeInterval(-1), listening: true).isEmpty)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none,
                                          now: opensAt, listening: true) == [rainPhrase])
    }

    // MARK: The user's own words come first

    /// §4A rule 2, and the rule this milestone turns on. `NotificationCopy.Digest.lead`
    /// already ranks note → place → soundprint; the card is that precedence on a
    /// second surface. The guess fills a silence; it never competes.
    @Test func aCardWithANoteShowsNoGuess() throws {
        let capsule = try rainy(note: "the storm broke")
        #expect(SoundprintDisplay.phrases(for: capsule, on: .card, rejecting: .none, listening: true).isEmpty)
    }

    /// And the detail screen still shows it, because there it sits *below* the note
    /// rather than in its place. Same capsule, different surface — which is the entire
    /// difference between the two cases.
    @Test func theDetailScreenShowsTheGuessBeneathANote() throws {
        let capsule = try rainy(note: "the storm broke")
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: true) == [rainPhrase])
    }

    /// A note of spaces is not a note. `Digest.lead` trims before deciding, and if
    /// these two disagreed the card and the lock screen would disagree about the same
    /// capsule.
    @Test func aWhitespaceOnlyNoteDoesNotSuppressTheGuess() throws {
        let capsule = try rainy(note: "   \n  ")
        #expect(SoundprintDisplay.phrases(for: capsule, on: .card, rejecting: .none, listening: true) == [rainPhrase])

        let digest = NotificationCopy.Digest(createdAt: .now, note: "   \n  ", placeName: nil,
                                             mood: nil, soundprint: Soundprint(stored: capsule.soundprintRaw), rejected: .none)
        #expect(digest.lead == .heard(rainPhrase), "and the two surfaces agree about what a note is")
    }

    // MARK: Showable, not merely stored (§4C)

    @Test func aCapsuleWhoseLabelsAreAllUnshowableShowsNothing() throws {
        let capsule = try rainy(labels: [("waterfall", 0.35), ("crying_sobbing", 0.99)])
        #expect(Soundprint(stored: capsule.soundprintRaw)?.hasNoLabels == false, "stored, though")
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: true).isEmpty)
        #expect(SoundprintDisplay.phrases(for: capsule, on: .card, rejecting: .none, listening: true).isEmpty)
    }

    @Test func aNeverAnalysedCapsuleShowsNothing() throws {
        let capsule = try rainy()
        capsule.soundprintRaw = nil
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: true).isEmpty)
    }

    @Test func anAnalysedButSilentCapsuleShowsNothing() throws {
        let capsule = try rainy()
        capsule.soundprintRaw = Soundprint.emptyMarker(classifier: "version1")
        #expect(SoundprintDisplay.phrases(for: capsule, on: .detail, rejecting: .none, listening: true).isEmpty)
    }

    // MARK: Attribution is in the copy (§4A rule 1)

    /// The sentence must name the guesser. A bare noun in a caption position reads as
    /// something the person wrote about their own memory, which is rule 1 failing in
    /// the quietest possible way.
    @Test func theSentenceNamesSoundpost() {
        let sentence = SoundprintDisplay.sentence(for: [rainPhrase])
        #expect(sentence?.contains("Soundpost") == true)
        #expect(sentence?.contains(rainPhrase) == true)
        #expect(sentence != rainPhrase, "never the bare phrase on its own")
    }

    @Test func theSentenceJoinsSeveralPhrases() {
        let wind = try! #require(SoundVocabulary.displayName(for: "wind"))
        let sentence = try! #require(SoundprintDisplay.sentence(for: [rainPhrase, wind]))
        #expect(sentence.contains(rainPhrase))
        #expect(sentence.contains(wind))
    }

    @Test func thereIsNoSentenceWithoutAPhrase() {
        #expect(SoundprintDisplay.sentence(for: []) == nil)
    }
}

/// §4A rule 3 — the guess never reaches anything that leaves the app.
///
/// `ShareCardView` takes a whole `Capsule`, and the exported video is a rasterised
/// `ShareCardView`, so **nothing structural** stops a future edit reading
/// `soundprintRaw` there and putting a machine's guess into an image someone posts.
/// This test is what stands in for that missing structure: it reads the source and
/// asserts an absence, which is the only direction that can fail for something that
/// was added rather than removed (M15 §11P).
///
/// It is a blunt instrument and says so. It cannot tell a reference from a comment
/// about one — which is why the files it guards must simply never mention the word.
struct SoundprintNeverLeavesTheAppTests {

    /// The repository root, from this file's own compile-time path. If it cannot be
    /// found the test **fails**: a guard that quietly finds nothing to check is the
    /// exact failure this repository keeps rediscovering.
    private func projectRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundpostTests/
            .deletingLastPathComponent()   // repo root
        let marker = root.appending(path: "Soundpost.xcodeproj", directoryHint: .isDirectory)
        try #require(FileManager.default.fileExists(atPath: marker.path),
                     "could not locate the repository root from #filePath — this guard checked nothing")
        return root
    }

    @Test func noExportSurfaceReadsWhatSoundpostHeard() throws {
        let root = try projectRoot()
        // Every file that renders, rasterises or packages something the user can send
        // to another person.
        let guarded = [
            "Soundpost/Views/ShareCardView.swift",
            "Soundpost/Services/CapsuleExporter.swift",
            "Soundpost/Services/VideoExporter.swift",
        ]
        for relative in guarded {
            let url = root.appending(path: relative)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                      "\(relative) is not where this guard expects it")
            #expect(!source.localizedCaseInsensitiveContains("soundprint"),
                    "\(relative) must never read what Soundpost heard — it leaves the app (§4A rule 3)")
            #expect(!source.localizedCaseInsensitiveContains("SoundVocabulary"),
                    "\(relative) must never name a sound label — it leaves the app (§4A rule 3)")
        }
    }

    /// And the guard itself must be able to fail: if `ShareCardView` were renamed or
    /// moved, the loop above would read nothing and pass. Pin that the files it names
    /// are the files that exist.
    @Test func theGuardIsPointedAtRealFiles() throws {
        let root = try projectRoot()
        for relative in ["Soundpost/Views/ShareCardView.swift",
                         "Soundpost/Services/CapsuleExporter.swift",
                         "Soundpost/Services/VideoExporter.swift"] {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: relative).path),
                    "\(relative) has moved; this guard is now checking nothing")
        }
    }
}
