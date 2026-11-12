import Foundation
import Testing

/// The app's name, in every language the app speaks (M23 S6).
///
/// The S6 witness pass found the Settings section's Shortcuts link reading 「のショートカット」 in
/// Japanese and 「快捷指令」 in Chinese — "Soundpost shortcuts" with the name gone. The link
/// takes the name from the *current language's* InfoPlist strings and does not fall back to
/// Info.plist, and `CFBundleName` was marked "don't translate", so only `en.lproj` carried
/// it. So the built app is read here, not the catalog: each language's compiled strings must
/// carry the name themselves.
struct AppNameLocalizationTests {
    private static let languages = ["en", "ja", "zh-Hans"]

    @Test(arguments: languages)
    func eachLanguageCarriesTheAppsName(_ language: String) throws {
        let url = try #require(
            Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil,
                            localization: language),
            "the app has no \(language) InfoPlist.strings")
        let strings = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(strings["CFBundleName"] == "Soundpost",
                "\(language): the Shortcuts link would draw without the app's name")
    }

    /// A fourth language added later is checked too, or this fails until it is.
    @Test func theLanguagesCheckedAreTheOnesTheAppShips() {
        #expect(Set(Bundle.main.localizations.filter { $0 != "Base" }) == Set(Self.languages))
    }
}
