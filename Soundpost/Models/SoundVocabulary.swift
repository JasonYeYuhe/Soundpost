import Foundation

/// The only sounds Soundpost will ever name (M15 §4D / §4D-bis).
///
/// Apple's classifier knows 303 things. Most of them are not what this app is for,
/// several would be actively unkind to put on a lock screen, and every one we *do*
/// show costs three languages of copy. So the vocabulary is a **deliberate,
/// curated allow-list**, and anything outside it is invisible by construction —
/// `SoundprintService` never even stores an unlisted label.
///
/// That makes "we cannot say it nicely in three languages" and "we will not say it"
/// the same thing, which is the property that keeps this milestone finite.
enum SoundVocabulary {

    /// Classifier identifier → the English phrase we show.
    ///
    /// Each phrase is written to read correctly **both** standalone (as a chip on a
    /// card) and slotted into a sentence — "Sounds like *a dog barking*". EN, JA and
    /// ZH-Hans all lack grammatical gender and articles-by-agreement, so one noun
    /// phrase per label composes cleanly in all three and we do not need a separate
    /// fragment per sentence shape.
    ///
    /// The English phrase is also the localization key, matching the rest of the app.
    static let displayNames: [String: String] = [
        // — Weather and water ------------------------------------------------
        "rain": "rain",
        "raindrop": "raindrops",
        "thunderstorm": "a thunderstorm",
        "wind": "wind",
        "wind_rustling_leaves": "leaves in the wind",
        "ocean": "the ocean",
        "sea_waves": "waves",
        "stream_burbling": "a stream",
        "waterfall": "a waterfall",
        "fire_crackle": "a crackling fire",

        // — Birds, animals, insects ------------------------------------------
        "bird_chirp_tweet": "birdsong",
        "crow_caw": "crows",
        "owl_hoot": "an owl",
        "cricket_chirp": "crickets",
        "frog_croak": "frogs",
        "dog_bark": "a dog barking",
        "cat_meow": "a cat",
        "cat_purr": "purring",
        "bee_buzz": "bees",
        "insect": "insects",

        // — People, warm only (see `denied`) ----------------------------------
        "laughter": "laughter",
        "baby_laughter": "a baby laughing",
        "giggling": "giggling",
        "applause": "applause",
        "cheering": "cheering",
        "crowd": "a crowd",
        "chatter": "chatter",
        "humming": "humming",
        "whistling": "whistling",
        "speech": "voices",

        // — Music -------------------------------------------------------------
        "singing": "singing",
        "music": "music",
        "piano": "a piano",
        "guitar": "a guitar",
        "violin_fiddle": "a violin",

        // — Getting around -----------------------------------------------------
        "traffic_noise": "traffic",
        "car_passing_by": "a passing car",
        "train": "a train",
        "subway_metro": "the subway",
        "aircraft": "a plane overhead",
        "helicopter": "a helicopter",
        "church_bell": "church bells",

        // — Home ---------------------------------------------------------------
        "cutlery_silverware": "cutlery",
        "dishes_pots_pans": "dishes",
        "frying_food": "something frying",
        "chopping_food": "chopping",
        "boiling": "something boiling",
        "liquid_pouring": "pouring",
        "water_tap_faucet": "a running tap",
        "typing_computer_keyboard": "typing",
        "clock": "a ticking clock",
        "vacuum_cleaner": "a vacuum",
    ]

    /// Sounds we **refuse to name**, even when the classifier is certain.
    ///
    /// This list is not the inverse of the allow-list — most of the other 250 labels
    /// are merely uninteresting. These are the ones that are *deliberately* excluded,
    /// recorded with their reason so the decision is auditable rather than folklore
    /// (M15 §4D-bis, raised by the Codex review and confirmed against the real
    /// vocabulary).
    ///
    /// The reasoning: a confidence floor filters *uncertain* labels, and does nothing
    /// about labels that are confidently correct but cruel. "A moment with crying"
    /// on a lock screen is a categorically different product from "a moment with
    /// rain" — and these classes are acoustically distinctive, so filtering by
    /// confidence makes surfacing them *more* likely, not less.
    ///
    /// Grouped by why:
    ///  * **distress** — someone's worst day is not a caption.
    ///  * **bodily** — private, and nobody wants it attached to a memory.
    ///  * **alarming** — violence and emergencies; a resurfacing should never startle.
    static let denied: Set<String> = [
        // distress
        "crying_sobbing", "baby_crying", "screaming", "shout", "yell",
        "children_shouting", "battle_cry", "gasp", "sigh", "booing",
        // bodily
        "breathing", "snoring", "cough", "sneeze", "hiccup", "burp",
        "nose_blowing", "gargling", "slurp", "chewing", "biting", "whispering",
        "toilet_flush", "bathtub_filling_washing", "sink_filling_washing",
        "toothbrush", "electric_shaver",
        // alarming
        "gunshot_gunfire", "artillery_fire", "glass_breaking", "slap_smack",
        "eruption", "firecracker", "air_horn", "snake_hiss", "snake_rattle",
        "siren", "police_siren", "ambulance_siren", "fire_engine_siren",
        "civil_defense_siren", "emergency_vehicle", "smoke_detector", "alarm_clock",
    ]

    /// Whether this label may ever be shown. The allow-list is the whole answer;
    /// `denied` exists to be *documented* and to be asserted disjoint from it.
    static func isAllowed(_ identifier: String) -> Bool {
        displayNames[identifier] != nil
    }

    /// The localized phrase for a label, or `nil` if we do not name this sound.
    ///
    /// `String(localized:)` over a runtime key: Xcode cannot extract these, so the
    /// catalogue is maintained deliberately and `scripts/check-sound-vocabulary.sh`
    /// gates that every phrase here exists and is translated.
    static func displayName(for identifier: String) -> String? {
        guard let english = displayNames[identifier] else { return nil }
        return String(localized: String.LocalizationValue(english))
    }

    /// Every allowed identifier, sorted — for tests and for the S4 search index.
    static var allowedIdentifiers: [String] { displayNames.keys.sorted() }
}
