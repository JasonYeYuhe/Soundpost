import Testing
@testable import Soundpost

/// The curated vocabulary's identifiers, pinned (M20 §4B).
///
/// An identifier is not a label we can rename freely: it is what `soundprintRaw`
/// stores on every analysed capsule and what every `SoundRejection` row names, and
/// both sync. Rename `"rain"` and every stored "rain" and every correction of it
/// silently stops matching anything — the display gate, the search index and the
/// rejection index all key on the identifier. `check-sound-vocabulary.sh` cannot see
/// that: it checks the English phrases are translated, and a rename keeps the phrase.
///
/// So the set is written out here, and changing it fails until this list changes in
/// the same commit as the migration that carries stored identifiers across. Adding a
/// new identifier is safe (nothing stores it yet) and only needs the list updated.
@Suite("The vocabulary's identifiers are pinned")
struct VocabularyPinTests {
    static let pinned: [String] = [
        "accordion", "aircraft", "applause", "baby_laughter", "bee_buzz", "bicycle_bell",
        "bird_chirp_tweet", "blender", "boiling", "car_passing_by", "cat_meow", "cat_purr",
        "cello", "chatter", "cheering", "choir_singing", "chopping_food", "chopping_wood",
        "church_bell", "clock", "coin_dropping", "cow_moo", "cricket_chirp", "crow_caw", "crowd",
        "crumpling_crinkling", "cutlery_silverware", "dishes_pots_pans", "dog_bark", "door_bell",
        "door_slam", "drawer_open_close", "duck_quack", "fire_crackle", "flute", "frog_croak",
        "frying_food", "giggling", "glass_clink", "guitar", "hair_dryer", "harmonica", "harp",
        "helicopter", "horse_clip_clop", "humming", "insect", "keys_jangling", "knock", "laughter",
        "liquid_dripping", "liquid_pouring", "liquid_trickle_dribble", "mechanical_fan",
        "microwave_oven", "music", "ocean", "orchestra", "owl_hoot", "piano", "pigeon_dove_coo",
        "printer", "rain", "raindrop", "rooster_crow", "saxophone", "scissors", "sea_waves",
        "sewing_machine", "sheep_bleat", "singing", "speech", "stream_burbling", "subway_metro",
        "thunder", "thunderstorm", "traffic_noise", "train", "train_whistle", "trumpet",
        "typewriter", "typing_computer_keyboard", "ukulele", "vacuum_cleaner", "violin_fiddle",
        "water_tap_faucet", "waterfall", "whistling", "wind", "wind_chime", "wind_rustling_leaves",
        "writing", "zipper"
    ]

    @Test func theAllowedIdentifiersAreExactlyThePinnedSet() {
        let actual = Set(SoundVocabulary.allowedIdentifiers)
        let pinned = Set(Self.pinned)
        #expect(actual.subtracting(pinned).sorted() == [], "added without updating the pin")
        #expect(pinned.subtracting(actual).sorted() == [], "removed or renamed — stored identifiers would orphan")
        #expect(Self.pinned.count == pinned.count, "the pin lists an identifier twice")
    }
}
