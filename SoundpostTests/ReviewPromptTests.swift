import Testing
import Foundation
@testable import Soundpost

/// The milestone review prompt cap (§S5): eligible at most once per app version,
/// and the cap survives relaunches (it's persisted).
@Suite(.serialized)
@MainActor
struct ReviewPromptTests {
    private func reset() { UserDefaults.standard.removeObject(forKey: ReviewPrompt.lastVersionKey) }

    @Test func promptsOncePerVersionThenCaps() {
        reset(); defer { reset() }
        #expect(ReviewPrompt.claimPrompt(version: "1.4.0") == true)   // first genuine resurface
        #expect(ReviewPrompt.claimPrompt(version: "1.4.0") == false)  // capped within the version
        // Persisted, so a fresh read (a relaunch) still caps.
        #expect(UserDefaults.standard.string(forKey: ReviewPrompt.lastVersionKey) == "1.4.0")
        #expect(ReviewPrompt.claimPrompt(version: "1.4.0") == false)
    }

    @Test func aNewVersionEarnsANewPrompt() {
        reset(); defer { reset() }
        #expect(ReviewPrompt.claimPrompt(version: "1.4.0") == true)
        #expect(ReviewPrompt.claimPrompt(version: "1.5.0") == true)   // new version → eligible again
        #expect(ReviewPrompt.claimPrompt(version: "1.5.0") == false)
    }
}
