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
        "thunder": "thunder",
        "wind_chime": "wind chimes",
        "liquid_dripping": "dripping",
        "liquid_trickle_dribble": "trickling water",

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
        "pigeon_dove_coo": "doves",
        "duck_quack": "ducks",
        "rooster_crow": "a rooster",
        "cow_moo": "cows",
        "sheep_bleat": "sheep",
        "horse_clip_clop": "hoofbeats",

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
        "cello": "a cello",
        "flute": "a flute",
        "saxophone": "a saxophone",
        "trumpet": "a trumpet",
        "harmonica": "a harmonica",
        "accordion": "an accordion",
        "harp": "a harp",
        "ukulele": "a ukulele",
        "orchestra": "an orchestra",
        "choir_singing": "a choir",

        // — Getting around -----------------------------------------------------
        "traffic_noise": "traffic",
        "car_passing_by": "a passing car",
        "train": "a train",
        "subway_metro": "the subway",
        "aircraft": "a plane overhead",
        "helicopter": "a helicopter",
        "bicycle_bell": "a bicycle bell",
        "train_whistle": "a train whistle",
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
        "sewing_machine": "a sewing machine",
        "typewriter": "a typewriter",
        "mechanical_fan": "a fan",
        "hair_dryer": "a hairdryer",
        "blender": "a blender",
        "microwave_oven": "a microwave",
        "printer": "a printer",
        "door_bell": "a doorbell",
        "drawer_open_close": "a drawer",
        "keys_jangling": "keys",
        "glass_clink": "clinking glasses",
        "coin_dropping": "a dropped coin",
        "zipper": "a zip",
        "scissors": "scissors",
        "crumpling_crinkling": "crinkling paper",
        "chopping_wood": "chopping wood",
        "knock": "a knock",
        "writing": "writing",
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
    ///  * **animal distress** — the same principle, for the animals in someone's life.
    ///  * **not a sound in the room** — an artefact of our recording, or the absence
    ///    of sound. Naming these describes our equipment or nothing at all, and
    ///    "your memory was silence" is the plainest possible version of telling
    ///    someone their memory was something it wasn't.
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
        // animal distress
        "dog_growl", "dog_whimper", "dog_howl", "coyote_howl", "lion_roar",
        // interpersonal judgement — "a snicker" imputes derision to someone in the room
        "snicker",
        // not a sound in the room
        "silence", "wind_noise_microphone",
        // a slammed door is far likelier to be an argument than a keepsake
        "door_slam",
    ]

    /// Whether this label may ever be shown. The allow-list is the whole answer;
    /// `denied` exists to be *documented* and to be asserted disjoint from it.
    static func isAllowed(_ identifier: String) -> Bool {
        displayNames[identifier] != nil
    }

    /// Labels that must clear more than the default confidence before Soundpost will
    /// say them out loud.
    ///
    /// A single global floor assumes every label is equally easy to confuse, and it
    /// is not. Measured on real AAC clips against the real `.version1` classifier:
    /// low-passed noise at the level of a quiet room (rms 0.0045–0.010) returns
    /// **`waterfall` at 0.30–0.38 on 2 clips in 12** — comfortably over the 0.30
    /// floor. Broadband room tone is spectrally close to running water, so the model
    /// is doing something reasonable and the floor is simply in the wrong place for
    /// this label. Rendering "a waterfall" for a recording of an empty room is
    /// exactly what §1.2 forbids.
    ///
    /// 0.45 clears every false positive observed (max 0.38) with margin. It is
    /// **provisional in one direction**: it was calibrated against negatives only, so
    /// it is known to remove these false labels and is *not* yet known to preserve
    /// real waterfalls — that needs a true-positive corpus, which is why this is a
    /// raised floor rather than a removal from the allow-list.
    ///
    /// `waterfall` is the only entry with measured evidence. Do not add others by
    /// intuition; measure them the same way first.
    static let elevatedConfidenceFloors: [String: Double] = [
        "waterfall": 0.45,
    ]

    /// The confidence a label must reach, which is the default unless it is a known
    /// confusable.
    static func confidenceFloor(for identifier: String, default defaultFloor: Double) -> Double {
        max(defaultFloor, elevatedConfidenceFloors[identifier] ?? 0)
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
