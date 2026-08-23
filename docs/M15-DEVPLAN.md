# Soundpost M15 — "Soundpost listens with you" (on-device sound understanding)

> Development plan for the phase after M14. Status feeding in (2026-08-02):
> **M14 SHIPPED** to the codebase (1.5.0 / build 10 uploaded & VALID, not submitted —
> 1.4.0 is still `WAITING_FOR_REVIEW`). Standing bars: **271 tests / 0 warnings /
> i18n EN·JA·ZH-Hans 100% / zero new third-party deps**. CI green (macos-26 /
> Xcode 26.5). Live App Store version **1.3.0**. Deployment target **iOS 17.0**.
> M10 delivery backend live (**do not touch**).
>
> This is the milestone Jason asked to be **big**, and to bring AI in.

---

> ## Status: **M15 CLOSED — 1.6.0 (build 12) LIVE on the App Store, 2026-08-12**
>
> **395 tests / 0 warnings / i18n EN·JA·ZH-Hans 100% / 52 sound labels translated /
> zero new third-party deps**, CI green, deployment target still **iOS 17.0**.
>
> **What shipped in 1.6.0 is build 12 = `8ef7f29`.** Everything from `b4c72a0`
> onward — account-wide consent, gate versioning and remediation, the amplitude
> gate's real peak, the AI sentence's language handling, CJK search, the drained
> backfill — is on `master` for the next version and is **not** in the live app. In
> particular 1.6.0 still carries the amplitude-gate defect described in §11C; §11E is
> what reopens the capsules it wrote off, and that only helps once the next version
> ships.
>
> **Before the next release:** `CD_ListeningConsent` must reach CloudKit Production
> (§11B-i). `build-upload-asc.sh` refuses to upload until it does, so this is a gate
> rather than something to remember.
>
> | Step | Commit | What it turned out to be about |
> |---|---|---|
> | S1 — service + model field | `7c83819` | the *gates*, not the model: silence classifies as `music 0.25` |
> | S2 — vocabulary | `b5b2f14` | 52 labels named, **44 refused**; a new CI gate for the copy |
> | S3 — capture suggestions | `38f1412` | suggest a line, never a mood |
> | S4 — search by sound | `674394d` | the `rain`/`train` false positive |
> | S5 — consent + resurface copy | `aeb211c` | two layered switches, not one overloaded one |
> | S7 — backfill + privacy re-audit | `32174f2`, `0470f03` | idempotence, and a consent bug the tests caught |
> | S6 — Apple Intelligence line | `d030fd5` | guardrails around a model that could invent |
>
> **Deviation from this plan, deliberate:** S3 was specified to include a *suggested
> mood chip*. It was dropped. Suggesting a note is a claim about the world; suggesting
> a mood is a claim about the person, which is the emotion-inference §2 already put
> out of scope. The classifier suggests what it heard; how it felt stays the user's.
>
> **Three corrections to this table, made 2026-08-07.** S1 cited `3662650`, which is
> "fix a redundant `try? #require` that tripped the warning gate" — a four-line test
> change, not the step. The implementation is `7c83819`. The refusal count was 45; the
> deny-list holds 44 unique identifiers. The test count was 322 against an actual 323.
> An earlier pass had "verified" these hashes by checking they *resolve* — which
> `3662650` does. Resolving is not identifying.

## Post-submission audit (2026-08-07)

A pre-submission audit of 1.6.0 found three things that should not have shipped, all
fixed in `8ef7f29` before build 12 was submitted:

| Finding | Why it mattered |
|---|---|
| "no audio is ever uploaded" — release notes **and** the Listening footer | False. `Capsule.audioData` rides the CloudKit-mirrored schema into the user's private database. Contradicted the iCloud row in the same Settings screen. Now claims only what is true: the *analysis* is on-device |
| Store description said "no cloud backup yet" | False since 1.3.0, and unnoticed because `asc.py` had no `description` push path at all — nothing in the release flow could see the drift |
| Withdrawing listening consent left the label on the lock screen | `contentVersion` guarded exactly this hazard for the personalized toggle (§S3 P0) and was never extended to the listening switch |

The audit's remaining findings were triaged after submission; these are fixed on
`master` for the next release:

| # | Fix |
|---|---|
| Erase had zero coverage | `forgetAllSoundprints` was a private method inside `SettingsView`, unreachable from the test target — the one M15 rule with no test, and the one the release notes name. Extracted to `SoundprintEraser` and covered |
| Backfill could undo the erase | The batch read consent once at entry, then classified up to 20 clips across as many awaits. Consent withdrawn mid-batch was ignored and the batch saved labels on top of the capsules just cleared. Results are now staged and applied only after re-confirming consent — staged rather than rolled back, because `rollback()` does not restore already-materialised objects |
| The amplitude gate measured the wrong thing | `minimumPeak` is documented as an absolute peak but was handed `Extraction.peak`, a *bucket average* — and one that moves with a waveform-drawing parameter that differs per call site (capture 56, backfill 32). The same quiet recording could clear the gate at capture and fail it at backfill, which then wrote the terminal "nothing to say" marker and put the capsule permanently beyond both search and retry. `Extraction` now carries a true per-frame `absolutePeak` |
| `asc.py` could act on the wrong version | `editable_version()` returned the first editable version of an unordered list, and `EDITABLE_STATES` includes the rejection states. A rejected 1.5.0 beside a 1.6.0 draft could have had its listing rewritten with 1.6.0's copy. It now matches the project's `MARKETING_VERSION` and refuses anything else |

**Still open**, carried to the next milestone — see §11.

## 0. Goal & success statement

Today a capsule is a waveform: beautiful, but **opaque**. You cannot search it, the
gallery cannot summarise it, and six months later "what was that one?" has no answer
but tapping play. PROJECT.md §1c names this exactly: *"sound is invisible/intangible
→ the card UI must make it glanceable"*, and *"capture frequency is the existential
risk"*.

M15 makes every capsule **know what it is**. Apple's on-device sound classifier
labels the recording (`rain`, `bird_chirp_tweet`, `traffic_noise`, `laughter`,
`cutlery_silverware`…), and that one new fact flows everywhere: the capture flow
suggests a mood and a line, the gallery becomes searchable *by sound*, and the
resurface moment can say *"a rainy morning, eight months ago"*.

**Done when:** a capsule carries an on-device **soundprint**; capture offers honest
suggestions the user may take or ignore; search finds "rain"; the resurface copy can
use it (respecting consent); all of it runs with **no network call, no inference
server, and no new third-party dependency** — the labels living with the capsule in
the user's own iCloud, like their note; standing bars hold.

### 0A. Why this and not "AI transcription"

PROJECT.md cut **AI transcription** from MVP as *"a different (crowded) product"* —
it is precisely what **Untold** ("the transcript is the unit, audio is disposable")
and **Diarly** do, and competing there abandons the one space PROJECT.md §1c found
open. So M15's AI is **sound understanding, not speech-to-text**: it describes *what
the world sounded like*, which is the thing no incumbent does. Transcription stays
out (§11).

## 1. Non-negotiables (carried from PROJECT.md / M9–M14)

1. **Never charge to receive a memory.** Sound labels make memories *findable*;
   finding your own memories is not a paid feature. Labelling, search and the
   resurface copy are **free** (§4F).
2. **Honest limits.** A classifier **guesses**. The UI must always say "sounds like",
   never assert; the user can correct or clear it; low-confidence guesses are simply
   not shown. Soundpost must never tell someone their memory was something it wasn't.
3. **Calm, no dark patterns.** Suggestions, never automation-behind-your-back. No
   "insights" feed, no streaks, no badges.
4. **Privacy-first — and precision matters here more than anywhere.** Two claims that
   must never be conflated (Codex F1, P0):
   - **Inference is 100% on-device.** `SoundAnalysis` opens no network connection;
     there is no inference server, and audio never leaves the phone for analysis.
   - **The resulting labels are stored on `Capsule`, which IS CloudKit-mirrored**
     (`SoundpostModelContainer` uses `cloudKitDatabase: .automatic`). So labels sync
     to the **user's own private iCloud database**, exactly like their note and
     waveform. Saying "nothing ever leaves the device" would be **false**. The honest
     sentence is: *"Soundpost listens on your device; what it hears is stored with
     your capsule and syncs only to your own iCloud."*
   Labels are **the user's private words** in the same sense a note is, so their use
   in a notification obeys `NotificationPreferences.personalized` (M12 §S3) — but see
   §4I: that toggle is **not sufficient consent** for the analysis itself. No new
   Required-Reason API; no ASC nutrition-label change.
5. **Offline-first, no backend churn.** M10 backend and M11/M14 gating untouched. The
   server stays **content-free** — labels are composed into copy **on the device**.
6. **No regression / standing bars:** warning-free on Xcode 26; ALL tests green; i18n
   EN·JA·ZH-Hans 100% **every step**; **zero new third-party deps** (SoundAnalysis is
   first-party); CI green; crashes symbolicated. Each step compiles + passes tests +
   is **committed**, ending each commit with:
   `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
7. **Deployment target stays iOS 17.0.** The core needs nothing newer (§3A). Anything
   that needs iOS 26 is an availability-gated *bonus*, never a requirement.

## 2. Scope

**IN:** (a) `SoundprintService` — on-device classification of a captured clip;
(b) a `soundprint` field on `Capsule` (CloudKit-legal, additive); (c) capture-time
**suggestions** (mood + a starting line) the user accepts or ignores; (d) **search
and filter by sound** in the gallery; (e) **resurface copy** that can use the
soundprint, honouring the personalized-notifications opt-out; (f) a **backfill** for
existing capsules; (g) i18n of ~303 raw labels → human copy (§4D — the biggest
single risk); (h) an **optional, availability-gated Apple Intelligence** line for
iOS 26 devices (§4G).

**OUT (→ M16?):** speech transcription (§0A, ruled out); any server-side inference;
per-capsule custom models; emotion detection from voice (unreliable + ethically
loaded); an "insights"/analytics feed; the WidgetKit widget; the Swift 6 flip.

### 2A. Headline

**Every capsule knows what it is, and your phone is what figures that out.**
Committed core = S1–S5; S6 (Apple Intelligence) is explicitly droppable.

## 3. Current state (grounded — cite before you change)

| Concern | Where | Note for M15 |
|---|---|---|
| Capture → capsule | `Capture/CaptureViewModel.swift` (`finishRecording` extracts the waveform via `WaveformExtractor`), `CaptureView` review screen | The natural hook: classify right after the waveform is extracted, off the main actor. |
| Capsule model | `Models/Capsule.swift` — every property optional or defaulted, *"keep it that way so enabling CloudKit needs no scalar migration"* | The new field **must** be optional/defaulted. Store a compact string, not a new entity. |
| Waveform extraction | `Audio/WaveformExtractor.swift` — streaming, bounded memory, pure, file-driven, unit-tested offline | The exact shape to copy for `SoundprintService`. |
| Search / filter | `Services/GalleryBrowsing.swift` `GalleryFilter` — **visibility-aware** (never matches hidden words on a sealed-not-due capsule) | Sound labels are content → they must obey the same visibility rule. |
| Notification copy | `Services/NotificationCopy.swift` + `NotificationPreferences.personalized` (default **off**) | Labels in a notification body = private words on a lock screen → same opt-in. |
| Mood | `Models/Mood.swift` (7 cases, user-chosen) | Suggest, never set. Mood is the user's reading of the moment, not the classifier's. |
| Gate | `Models/ProGate.swift` | §4F: M15 adds **no** gate. |

### 3A. Capability probe (run 2026-08-02, on the iOS 26.5 simulator)

Measured, not assumed — `SoundpostTests/SoundClassifierProbeTests.swift` (throwaway,
deleted at S1):

- `SNClassifySoundRequest(classifierIdentifier: .version1)` — **iOS 15+**, so
  **available at our iOS 17 target with no bump**.
- **303 known labels.** Coverage of everyday-sound terms: **25/28** matched
  (`rain`, `raindrop`, `bird_chirp_tweet`, `laughter`, `crowd`, `traffic_noise`,
  `ocean`, `thunderstorm`, `cat_purr`, `typing`, `cutlery_silverware`,
  `wind_rustling_leaves`, `applause`, `church_bell`, …). Missing as literal terms:
  `footsteps`, `coffee`, `cooking` (partly covered by `cutlery_silverware`).
- **Fast:** 3-second clip classified in **0.02–0.05 s**. A 60 s clip is well under a
  second; the Pro 5-minute maximum is a few seconds, off-main.
- **Sane:** a 440 Hz tone → `tuning_fork 0.72 | bell 0.67 | beep 0.61`; low-passed
  rumble → `wind 0.17`; broadband hiss → `waterfall 0.11 | water 0.09`. Synthetic
  signals classify plausibly, which is the weakest case — real ambient audio is what
  the model was trained on.
- `FoundationModels` exists in the SDK but is **iOS 26+** → §4G, optional only.

**Second probe (post-Codex, same day) — two traps confirmed empirically:**

- **Digital silence is classified as `music 0.25 | synthesizer 0.13 | keyboard_musical
  0.10`.** A silent 3 s clip produces *confident nonsense*, and a 30 s silent clip
  produces 57 such callbacks. **Any confidence floor below ~0.25 would tell a user
  their silent recording "sounds like music".** → §4C now mandates an amplitude gate
  *before* analysis, not just a confidence floor after it.
- **A 0.5 s clip produces zero callbacks** — the analyzer completes with no results.
  An implementation that only writes state in `didProduce:` leaves the capsule in a
  permanent in-flight limbo. → §4A mandates an explicit terminal `.noResult`.
- **28 of the 303 labels are sensitive**: `crying_sobbing`, `baby_crying`,
  `screaming`, `shout`, `yell`, `children_shouting`, `battle_cry`, `gasp`, `sigh`,
  `breathing`, `whispering`, `snoring`, `cough`, `sneeze`, `hiccup`, `burp`,
  `slap_smack`, `gunshot_gunfire`, `glass_breaking`, `smoke_detector`, `alarm_clock`,
  and five siren classes. → §4E's deny-list is **mandatory, not optional**.

**Verdict: the feature is buildable at iOS 17, on-device, first-party, and cheap —
but only with the amplitude gate, the terminal no-result state, and the deny-list.**

## 4. Architecture / design decisions

**A. `SoundprintService` mirrors `WaveformExtractor`, and owns its analyzer.**
File-driven, off the main actor, unit-testable against a generated clip with no
microphone. Three things the API forces us to get right (Codex F3, P0):
- `SNAudioFileAnalyzer.add(_:withObserver:)` does **not retain the observer**. The
  service holds analyzer *and* observer strongly for the whole run, and bridges
  completion through a `withCheckedThrowingContinuation`.
- Callbacks arrive on an **internal queue**, not the main actor — so no `ModelContext`
  is touched from the callback; results hop to the model actor first.
- Outcomes are a closed enum: `.labels([...])`, or a **terminal `.noResult`** (too
  short, too quiet, or the analyzer completed with zero callbacks). There is no
  "still pending" state to get stuck in.

**B. Storage: a versioned compact string on `Capsule`.** `soundprintRaw: String?`,
optional + defaulted per `Capsule`'s standing CloudKit rule. Format carries its own
provenance (Codex F4/F13): `v1/version1|rain=0.82;wind=0.41` — schema version and
**classifier identifier**, so a future `.version2` taxonomy is distinguishable and
re-analysable rather than silently mixed. Parsed by a pure `Soundprint(stored:)`; a
corrupt value degrades to "no soundprint", never to wrong data.

**C. An amplitude gate BEFORE analysis, then a confidence floor after it.** The probe
proved a floor alone is not enough: **silence classifies as `music` at 0.25**. So:
1. **Duration gate** — under ~1.0 s (one classifier window) we do not analyse at all.
2. **Amplitude gate** — compute RMS/peak from the samples `WaveformExtractor` already
   produces (no second decode) and skip analysis of near-silent clips.
3. **Confidence floor** above the measured silence artefact, tuned in S2.
Below any gate Soundpost says **nothing** — no "unknown", no empty state. A wrong
guess about someone's memory is worse than no guess (§1.2).

**D-bis. A deny-list, and it is mandatory (Codex F7 — confirmed by probe).** 28 of
the 303 labels are distress, bodily, violent or emergency sounds. A resurface push
saying *"a moment with crying"* — or `screaming`, `gunshot_gunfire`, `snoring` — is a
categorically different product from *"a moment with rain"*, and confidence filtering
makes it **more** likely, not less, because those classes are acoustically
distinctive. Rules:
- Human-vocalisation, distress, medical, violent and emergency classes are **never**
  used in notification copy or capture suggestions.
- The allow-list is the only source of displayable labels; the deny-list is written
  down with its rationale so the decision is auditable, not folklore.

**E. Exact-token matching, never substring (Codex F4).** The probe already shows the
trap: searching `rain` substring-matches **`train`**, `train_whistle`, `raindrop`.
Matching is on whole label identifiers, and user-facing search maps a query to
label IDs through the vocabulary table — it never greps the stored blob.

**D. Labels → human copy is the hard part, not the ML.** 303 raw identifiers
(`bird_chirp_tweet`) must become natural EN·JA·ZH-Hans. Approach:
- Curate a **shortlist** of labels this app actually cares about (ambient life:
  weather, water, animals, transport, room tone, people, music, domestic) and map
  only those. Everything else is below the floor *by policy* — a label we cannot say
  nicely in three languages is a label we do not show.
- The map is a **pure, tested table**, not a runtime string-munge, so the localization
  gate covers every phrase we can emit.
- This bounds the i18n work to a deliberate set (target ≈40–60 labels), which is the
  difference between a shippable milestone and an endless one.
- **Budget sentences, not nouns (Codex F10).** A label is not a word we drop into a
  template — "a moment with rain" does not decline cleanly across EN/JA/ZH. Each
  allowed label ships **pre-composed per-locale fragments** in the catalogue, the way
  `NotificationCopy` already works. Realistic estimate: ~3 strings × label × locale.

**E. Suggest, never set.** The classifier may pre-fill *nothing*. It offers: a mood
chip suggestion and a tappable starting line ("Rain on the window"). The user taps to
accept. Declining is silent and permanent for that capsule.

**F. No new gate — M15 is free.** Finding your own memories is not a paid feature
(§1.1), and the classifier costs nothing per use. This milestone deliberately adds
**retention and differentiation**, not revenue. (Pro's story stays creation richness:
M11 themes/length/export, M13 video, M14 personalisation.)

**G. Apple Intelligence is a bonus, never the plan (S6, droppable).** On iOS 26 +
supported hardware, `FoundationModels` can turn *(labels, mood, place, date)* into one
warm sentence. Strictly `if #available` + capability-checked, with the S5 template
copy as the always-present fallback. It must never be the only path to a feature, or
we would be shipping a feature most of the install base cannot use.

**I. Analysis consent is its own switch (Codex F6).** Reusing the
notification-personalization toggle would be consent theatre: it governs *copy*, while
the analysis happens at capture time regardless. M15 adds **one** preference —
"Listen to my recordings on this device" — which governs whether classification runs
at all; the notification toggle stays downstream of it. Default and the
turn-it-off-afterwards behaviour (existing labels are **deleted**, not merely hidden)
are decided in S2 and stated in-app.

**J. A protocol seam so the ML is not in the test loop (Codex F11).**
`SoundClassifying` lets every downstream rule — gates, floor, deny-list, copy —
be tested against a stub. Exactly one integration test runs the real classifier
against a fixture clip and asserts **loosely** (top label ∈ expected set), so CI never
depends on Core ML output being bit-stable across OS versions.

**K. Classify off the critical path (Codex F12).** Capture already does one post-stop
file pass (`WaveformExtractor`). M15 must not add a second synchronous one in front of
the save. The capsule saves immediately; classification is deferred and asynchronous,
and the amplitude gate reuses the samples extraction already computed. Re-benchmark on
a 5-minute clip, not the 3-second probe.

**H. Backfill, reusing M9's proven shape.** Existing capsules get soundprints by a
one-shot `@ModelActor` background pass modelled on `AudioMigrator` — streaming, one
clip at a time, idempotent, cancellable, never blocking launch.

## 5. Work breakdown (sequenced; each step compiles + passes tests + commits)

**S1 — `SoundprintService` + the model field.** The service, the `Soundprint` value
type, `Capsule.soundprintRaw`, and classification wired into capture (off-main, never
blocking the review screen). Delete the throwaway probe. *Verify:* classifies a
generated clip; parse/serialise round-trip; garbage degrades to empty; a clip too
short to classify yields nothing rather than noise; capture still works when
classification fails.

**S2 — The label vocabulary + i18n.** The curated label→copy table for EN·JA·ZH-Hans,
the confidence floor tuned against real recordings, and the "say nothing when unsure"
rule. *Verify:* every mapped label has three translations (gate); unmapped labels are
never surfaced; a table-completeness test.

**S3 — Capture suggestions.** "Sounds like rain" on the review screen; tap to accept
into the note; a suggested mood chip. *Verify:* suggestions are never auto-applied;
declining leaves the capsule untouched; the flow is unchanged when there is no
soundprint.

**S4 — Search & browse by sound.** `GalleryFilter` matches soundprint labels, obeying
the **visibility rule** (never match a sealed-not-due capsule's hidden sound).
*Verify:* "rain" finds rainy capsules; a sealed-not-due capsule never matches on its
sound; free users have full search.

**S5 — The resurface moment.** Notification copy may use the soundprint, **gated on
the existing `personalized` opt-in**; the resurface view can show it. *Verify:* with
the toggle **off**, no label reaches a notification body; the server payload stays
content-free; copy is localized.

**S6 — Apple Intelligence line (optional, droppable).** `if #available(iOS 26)` +
capability check; S5 copy is the fallback. *Verify:* absent gracefully on iOS 17.

**S7 — Backfill + hardening + privacy re-audit.** The one-shot pass over existing
capsules (throttled, resumable, idempotent against the version field); performance and
memory sanity on a large library (benchmark a 5-min clip and a 500-capsule library,
not the 3 s probe); Settings control to clear all soundprints. **Privacy re-audit
(Codex F8):** re-read `NSMicrophoneUsageDescription` — it likely no longer describes
what the app does with the audio — re-check the ASC nutrition answers now that a
derived label syncs, and add a rule so a sound label can never reach a Sentry
breadcrumb or event payload.

> Drop order if tight: **S6 first** (it is explicitly a bonus), then S7's backfill
> (new capsules still get soundprints). **Never drop:** S2's "say nothing when
> unsure", S4's visibility rule, S5's opt-in check.

## 6. Privacy / legal delta

**No new data, no backend, no nutrition-label change — but this section carries more
weight than usual because "AI" is exactly where users assume the opposite.**

- `SoundAnalysis` runs **entirely on-device**; it opens no network connection. Nothing
  is uploaded, and there is no inference server to have a policy about.
- The soundprint is **derived from the user's own audio and stays with it**, on-device
  and in their own iCloud mirror (like the note and the waveform).
- It is **private words**: a label on a lock screen is the same exposure as a note, so
  it obeys `NotificationPreferences.personalized` (default off).
- The M10 server payload stays **content-free** — copy is composed on-device (M10 §4D).
- **No new Required-Reason API.** Reading our own clip is already covered by
  `FileTimestamp` C617.1.
- Re-verify PrivacyInfo + the ASC label at S7. Update the privacy policy page only if
  wording about "how your audio is used" needs to name on-device analysis — **worth
  saying out loud even though nothing changes**, because saying "we analyse your audio
  on your device and it never leaves" is a *feature*.

## 7. Risks & mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| A wrong guess misdescribes someone's memory | **High** | "Sounds like", never asserted; confidence floor; user can clear; below-floor = say nothing (§4C). |
| "AI" reads as surveillance / creepy | **High** | On-device stated plainly in-app and in the notes; no feed, no profiling; opt-out that actually removes the data (S7). |
| The 303→human-copy i18n becomes endless | **High** | §4D: curate ≈40–60 labels; unmapped is invisible by policy; a completeness test. |
| It feels gimmicky and breaks the calm | Med | Suggestions only; no badges/streaks/insights; it can be ignored forever without nagging. |
| CloudKit schema breakage | Med | One optional defaulted `String?` — the rule `Capsule` already documents. |
| Classifier weak on quiet/short clips | Med | Measured floor; short clips simply produce nothing (they already do — `windowDuration` ≈ 0.975 s). |
| Perf/memory on a 5-min clip or a big backfill | Low | Probe: 0.02–0.05 s per 3 s. Backfill copies `AudioMigrator`'s streaming shape. |
| iOS 26-only AI splits the experience | Med | §4G: bonus only, always with the S5 fallback; never the only path. |

## 8. Human-in-the-loop checklist (needs Jason)

- [ ] **Confirm the thesis:** sound *understanding* (what the world sounded like), and
  **not** speech transcription — which PROJECT.md cut as a different, crowded product.
- [x] **CONFIRMED 2026-08-04 (Jason): M15 ships entirely free**, paid features come later. Recorded because it is a one-way door — a capability shipped free cannot move behind Pro without backlash, so a future paid tier must be built from *new* value, not by fencing this off.
- [ ] ~~Confirm M15 ships free~~ (§4F) — Codex F9 pushed back on this: it is the
  hardest-to-copy thing in the app, and a capability shipped free cannot later move
  behind Pro without backlash. Its counter-proposal: classification + capture
  suggestions free (they make the app feel alive), **label-based search and
  personalized resurface copy behind `ProGate`**. My recommendation is still all-free —
  finding your own memories is not something to charge for (§1.1) — but this is your
  call and it is one-way.
- [ ] **Confirm the label shortlist** once S2 drafts it (~40–60 everyday sounds).
- [ ] **Release 1.4.0** when approved, and the 1.5.0 (M14) submission afterwards —
  M15 must not jump that queue (`asc.py` now refuses to touch a version in review).
- [ ] M13's leftover device check (`-runVideoSelfTest`) for render time/size.
- [ ] Deployment target **stays iOS 17**.

## 9. Reuse map

| Need | Source |
|---|---|
| Classification | first-party **`SoundAnalysis`** (`SNAudioFileAnalyzer` + `SNClassifySoundRequest`) |
| Streaming, file-driven, testable analysis | in-repo `WaveformExtractor` (the shape to copy) |
| Compact stored value + pure parser | in-repo `MoodPalette` (M14) |
| Background one-shot backfill | in-repo `AudioMigrator` (`@ModelActor`, streaming) |
| Visibility-aware search | in-repo `GalleryFilter` |
| Privacy-respecting notification copy | in-repo `NotificationCopy` + `NotificationPreferences` |
| Localized vocabulary | in-repo String Catalogs + `scripts/check-localization.sh` |

## 10. Acceptance criteria

1. A newly captured capsule carries an on-device soundprint; a clip that cannot be
   classified confidently carries **none**, and the UI says nothing about it.
2. Capture **suggests** a mood and a line; nothing is applied without a tap.
3. Gallery search finds capsules by sound, and a **sealed-not-due** capsule never
   matches on its hidden sound.
4. With personalized notifications **off**, no sound label reaches a notification body;
   the server payload remains content-free.
5. Every label the app can display has EN·JA·ZH-Hans copy; unmapped labels are
   unreachable.
6. **Standing bars:** warning-free; all tests green; i18n 100%; **zero new deps**; CI
   green; iOS 17 target unchanged; PrivacyInfo/nutrition label unchanged.
7. Nothing reaches the network because of this milestone — assertable by inspection:
   no new URLSession, no new endpoint.

## 11. Out of scope / next (M16?)

- **Speech transcription** (§0A) — ruled out; it is the competitors' product.
- Server-side inference of any kind.
- Emotion/stress detection from voice — unreliable and ethically loaded.
- An "insights"/analytics feed, streaks, or year-in-review.
- Custom-trained models (Create ML) — the built-in classifier is enough to prove it.
- WidgetKit widget; Swift 6 flip; promo/win-back codes.

### 11A. Known-open, from the 1.6.0 pre-submission audit

Ranked. Everything here was found before submitting 1.6.0 and deliberately not held
the release for; the first two are the ones with a user-visible promise attached.

| # | Open issue | Shape of the fix |
|---|---|---|
| ~~1~~ | ~~**The erase does not survive a second device.**~~ **Fixed** — consent is now account-wide. See §11B | — |
| 2 | **Capsules already mis-marked by the 1.6.0 amplitude gate stay stuck.** The gate is fixed on `master`, but 1.6.0 ships it, and a capsule it wrote `1/version1\|` onto is never reconsidered — the backfill only refetches `soundprintRaw == nil` | A one-time remediation pass that clears *empty* markers so they are re-analysed once under the corrected gate. Needs a way to tell an old marker from a new one — the stored form already carries a schema version |
| ~~3~~ | ~~**The Apple Intelligence sentence has no language control.**~~ **Fixed — §11F.** `SoundSummaryWriter.instructions` is English-only with no directive to answer in the user's language, and `validated()`'s refusal blocklist is English-only, so a Japanese refusal or preamble passes every guard and renders as if it described the memory | Add a language directive and a `SystemLanguageModel.supportedLanguages` check; widen or restructure the refusal guard. Gated behind iOS 26 + Apple Intelligence, and no shipped claim mentions it |
| ~~4~~ | ~~**"Search 'rain'" is eventually true, not immediately true.**~~ **Fixed — §11H.** Classification is async and `save()` persists whatever exists at that moment; the backfill does 20 capsules once per launch. A 300-capsule library needs ~15 launches, with no indication indexing is in progress | Either surface progress, or re-run the backfill within a session |
| ~~5~~ | ~~**The data export omits `soundprintRaw`.**~~ **Fixed** — the manifest now carries `soundsHeard` as display phrases. Derived personal data, synced to the user's iCloud, absent from the data-subject export. The Settings copy enumerates what is included, so it is incomplete rather than false | Add the field to `CapsuleBulkExporter`'s manifest |
| ~~6~~ | ~~**The "never auto-applies" regression guard is vacuous.**~~ **Fixed** — it now drives `save(using:)` with a soundprint present. `aSoundprintNeverAppliesItself` asserts nothing changed in a scenario where nothing *could* change — it never lands a soundprint. A future change that pre-seeded the note would pass | Drive `save(using:)` with a soundprint present and assert `note == nil` |
| ~~7~~ | ~~In ja/zh, search matches only the phrase-*leading* token~~ **Fixed — §11I.** (CJK has no spaces, and `matches(phrase:query:)` requires a word boundary), so さえずり finds nothing against 鳥のさえずり | Substring match for scripts without word boundaries |
| ~~8~~ | ~~Accepting a suggestion joins with an ASCII space~~ **Fixed.**, which is typographically wrong between CJK runs | Join without a space when neither side is Latin |
| ~~9~~ | ~~The 52 runtime-looked-up sound keys carry no `extractionState`~~ **Fixed** — all 52 marked `manual`., so a future Xcode cleanup can mark them stale and offer 52 hand-authored translations for removal. The four `push.*` keys already use `"manual"` for exactly this | Mark them `"manual"` |
| ~~10~~ | ~~`accessibilityLabel("Restore purchases")`~~ **Fixed** — both keys added and translated. / `("Manage subscription")` are absent from the catalog, so VoiceOver reads English on ja/zh. Pre-existing, not M15 | Add the two keys |
| ~~11~~ | ~~The "no label can reach Sentry" guarantee is convention on a `String` parameter, not a type.~~ **Fixed — §11J.** All 14 call sites pass literals today; `CaptureView` does put a sound phrase in an `accessibilityLabel`, and automatic breadcrumb tracking is left at its default | A type that only accepts static strings would make it structural |
| 12 | The ASC privacy nutrition label was asserted unchanged, but nothing in the repo can verify server-side state and `asc.py` has no read path for it | One manual check in ASC — the exact failure mode the re-audit existed to correct |

## 12. Review record (2026-08-02)

### 12A. Codex — 13 findings, verdict **REVISE**. All folded in above.

Codex raised four open questions; each was **checked against the code or the real
classifier** rather than assumed:

| # | Sev | Finding | Outcome |
|---|---|---|---|
| 1 | P0 | "Nothing leaves the device" is false — labels land on a CloudKit-mirrored model | **Confirmed** (`cloudKitDatabase: .automatic`). §1.4 rewritten to separate *on-device inference* from *syncs to your own iCloud*. Best finding of the pass. |
| 2 | P0 | Short/silent clips: no callbacks, or confident nonsense | **Confirmed and worse than guessed** — 0.5 s → 0 callbacks; **3 s of silence → `music 0.25`**. §4C now gates on duration *and* amplitude before analysis. |
| 3 | P0 | `add(_:withObserver:)` doesn't retain the observer; callbacks are off-main | **Confirmed** API semantics; Swift 5 mode so it is a latent race, not a compile error. §4A now specifies ownership + the model-actor hop. |
| 4 | P1 | Delimited blob: substring false positives, no taxonomy version | **Confirmed** — the probe itself shows `rain` matching **`train`**. §4B adds schema + classifier version; §4E mandates exact-token matching. |
| 5 | P1 | "Backfill is missing entirely" | **Incorrect** — §4H and S7 already specified it. Kept as-is. |
| 6 | P1 | Notification toggle is the wrong consent boundary for analysis | **Accepted** — §4I adds a separate "listen on this device" switch; the notification toggle sits downstream. |
| 7 | P1 | Confidence floor does nothing about *confidently harmful* labels | **Confirmed** — 28/303 are distress/bodily/violent/emergency (`crying_sobbing`, `screaming`, `gunshot_gunfire`, `snoring`…). §4D-bis makes the deny-list mandatory. |
| 8 | P1 | Privacy exposure asserted, not checked (mic string, Sentry) | **Accepted** — added to S7: re-read `NSMicrophoneUsageDescription`, add a Sentry scrubbing rule. |
| 9 | P1 | Shipping free contradicts §1c differentiation | **Accepted as a question for Jason** (§8). Recorded rather than silently defaulted. |
| 10 | P2 | i18n is sentences, not nouns | **Accepted** — §4D budgets ~3 fragments × label × locale. |
| 11 | P2 | Nondeterministic ML with no test strategy | **Accepted** — §4J adds a `SoundClassifying` seam + one loose integration test. |
| 12 | P2 | Classification competes with the existing post-capture file pass | **Accepted** — §4K defers it off the save path and reuses the extractor's samples. |
| 13 | P2 | The real risk is taxonomy drift, not deprecation | **Accepted** — §4B stores the classifier identifier. |

### 12B. Gemini — unavailable, same as M13

The CLI is **still tier-ineligible on this machine** (verified 2026-08-02:
`IneligibleTierError — this client is no longer supported for Gemini Code Assist for
individuals; migrate to Antigravity`). Identical blocker to M13 §12, five weeks on.
To get a Gemini 3.6 pass, paste this document into Gemini web / Antigravity by hand —
the plan is otherwise review-complete.

### 11B. Listening consent is account-wide (2026-08-08)

§11A #1 resolved. The switch was a per-device `UserDefaults` flag while its effect —
erasing every stored soundprint — went through the CloudKit-mirrored store and so
applied everywhere. A second device with listening still on backfilled the cleared
capsules and synced the labels home; search found them again on the very device
where the user had turned it off.

**Consent now lives in the SwiftData store**, as a `ListeningConsent` model that
mirrors through the existing CloudKit container.

*Why not `NSUbiquitousKeyValueStore`* — the textbook home for a small synced
setting, and it would have needed a new entitlement (`ubiquity-kvstore-identifier`)
plus a provisioning change. But the deciding reason is ordering, not provisioning:
KVS and the capsule store are two independent sync channels with no ordering
guarantee between them, so a device could observe "consent withdrawn" before or
after the erase that accompanied it and re-analyse in the gap. Keeping consent in
the same store as the data it governs means the decision and its effect travel
together, over one channel.

| Decision | Why |
|---|---|
| Resolution is **last-writer-wins** on `changedAt` | The most recent answer is the one the user meant. Not an off-latch: turning it back on later wins too |
| A **tie goes to off** | Device clocks differ. When we cannot tell which answer came last, honour the privacy-preserving one |
| **No row is seeded at launch** — absence means the default (on) | Seeding would have every device racing to create one, and a seeded row carries no user intent to preserve. The row is written only by a deliberate toggle |
| `SoundAnalysisPreferences` **stays** as a local mirror | Every gate reads it synchronously, often as a defaulted parameter. `ListeningConsentStore.applyToDevice` keeps it honest at launch and on each remote merge, so nothing else needed a `ModelContext` |
| `applyToDevice` erases **whenever consent is off**, not only on a transition | The erase and its consent record can arrive in either order, and a backfill batch can land between them. The invariant worth holding is "consent off ⇒ nothing stored here". A no-op when clean |
| Consent is adopted **before** the launch backfill and **before** notification bodies rebuild | Both read the mirror. A withdrawal made elsewhere has to land first, or this launch re-labels exactly what the user cleared |

Schema note: adding an entity is additive, so an existing store migrates lightly.
`ListeningConsent` is CloudKit-legal on the same terms as `Capsule` — no
`@Attribute(.unique)`, every property defaulted.

Copy: the toggle drops "on this device", and the footer says the setting follows the
iCloud account and that turning it off erases what was heard *everywhere*.

#### 11B-i. BLOCKING before this ships — promote the CloudKit schema

`ListeningConsent` is a new entity, which `NSPersistentCloudKitContainer` maps to a
new **`CD_ListeningConsent`** record type. That type is auto-created only in the
CloudKit **Development** environment; **Production is read-only from the client**,
and App Store / TestFlight builds talk to Production.

M9 recorded this as a discrete human step and it was done for `CD_Capsule`
(docs/M9-DEVPLAN.md:228). Nothing did it for this entity — §11B originally said only
"adding an entity is additive, so an existing store migrates lightly", which is true
of SwiftData's *local* migration and says nothing about the server side. That
sentence is exactly what stopped the thought.

**If this ships unpromoted the failure is silent by construction.** Schema legality
is validated locally, so the container stays on the CloudKit rung and nothing
throws; only the export of the new record type fails, server-side. Consent then
never syncs, `resolve()` falls back to the device mirror, and the feature degrades
to precisely the per-device bug it was written to fix — while the Settings footer
tells the user it "applies on every device you use Soundpost on".

- [x] ~~Create a CloudKit management token~~ — **not needed, one was already saved.**
      The `authorization-failed` that suggested otherwise came from passing the wrong
      team: `M3B2SV6M8B` is the **App ID resource** from an M9 checklist line, not the
      team. `DEVELOPMENT_TEAM` is `KHMK6Q3L3K`. A wrong team id reports identically to
      a missing token.
- [x] **Verified against the live container** (2026-08-08): Development holds
      `CD_Capsule` + `Users`, Production the same. `CD_ListeningConsent` is in
      **neither** — so there is nothing to promote yet, and the analysis that it
      would silently fail to sync is confirmed by observation, not inference.
- [ ] **Jason:** run a signed build on a device signed into iCloud and toggle
      Listening once. That write is what creates `CD_ListeningConsent` in
      Development; `cktool` cannot conjure a record type, and hand-authoring the
      schema risks a field mismatch Production could never take back.
- [ ] `./scripts/cloudkit-schema.sh status` — shows what each environment has and
      what the app's schema implies. Exits 2 when Production is behind.
- [ ] `CK_CONFIRM=yes ./scripts/cloudkit-schema.sh promote` — imports Development's
      schema into Production and verifies it afterwards.
- [ ] Only then archive and submit a build containing this entity.

**The step is now a gate, not a reminder.** `build-upload-asc.sh` runs
`cloudkit-schema.sh status` before an upload and refuses when Production is behind,
because remembering demonstrably did not work: M9 did the promotion by hand and wrote
it down, M15 added an entity and nobody carried it forward, and this plan's own
"adding an entity is additive" line was about SwiftData's *local* migration. Override
with `CK_SKIP_SCHEMA_CHECK=yes`, which prints what you are choosing to ship without.

`scripts/cloudkit-schema.sh` derives the expected record types from
`Schema([...])` in source rather than a hard-coded list, so the next entity cannot
slip past the same way this one did. Run `status` as part of release prep; it is the
check that did not exist when this was missed.

**What can be checked in software, and now is.** Every other test container passes
`cloudKitDatabase: .none` on purpose — `.automatic` spins up a mirroring delegate
that fails noisily on a signed-out simulator — which left the CloudKit rung itself
untested. That matters because of how it fails: `makeProductionContainer()` catches
*any* throw from rung 1 and falls through to a local store, so a CloudKit-illegal
schema produces no crash, no error, and no user-visible signal — just an app that
has quietly stopped syncing.

`CloudKitSchemaTests` loads **the shipping schema** (`SoundpostModelContainer.productionSchema`,
exposed rather than rebuilt so a test copy cannot drift from it) against a
CloudKit-backed configuration, and separately asserts the rules the schema comment
claims: no uniqueness constraints, every attribute optional or defaulted, every
relationship optional.

Verified by negative control rather than assumed: removing the default from
`ListeningConsent.enabled` makes it fail with the real thing —
*"CloudKit integration requires that all attributes be optional, or have a default
value set"* — and restoring it makes it pass. Two of the tests written for the
amplitude gate turned out to pass against the bug they guarded, so a new gate is not
trusted here until it has been seen to fail.

**It does not replace §11B-i.** Schema *legality* is a local check. Whether the
matching record type exists in CloudKit **Production** is a server-side deployment
that no test can reach, and from inside the app the two failures look identical.

The launch and merge paths now log through `Diagnostics` instead of swallowing the
error with `try?`, so a failure is at least observable in Console — but logging is
not a substitute for the promotion, and there is no in-app signal that consent
failed to sync.

### 11C. The amplitude gate, measured (2026-08-08)

A review of the gate change recommended raising `minimumPeak` from 0.02 to 0.10, on
the reasoning that the new input (a per-frame absolute peak) reads ~5x higher than
the old one (a bucket average), so the threshold should scale with it. **Measured,
and rejected.** Probed on real AAC clips against the real `.version1` classifier —
low-passed noise at 14 levels, 12 trials each, plus digital silence and
burst-in-quiet clips.

| rms | absPeak | peak@32 | old gate | new gate | stored a label |
|---|---|---|---|---|---|
| 0.0012 | 0.0186 | 0.0147 | 0/12 | 0/12 | 0/12 |
| **0.0015** | **0.0232** | **0.0183** | **0/12** | **12/12** | **0/12** |
| 0.0018 | 0.0279 | 0.0220 | 12/12 | 12/12 | 0/12 |
| 0.0045 | 0.0697 | 0.0550 | 12/12 | 12/12 | 2/12 `waterfall` 0.37–0.38 |
| 0.0060 | 0.0928 | 0.0733 | 12/12 | 12/12 | 2/12 `waterfall` 0.32–0.33 |
| 0.0100 | 0.1544 | 0.1222 | 12/12 | 12/12 | 2/12 `waterfall` 0.30–0.32 |
| 0.0280+ | ≥0.43 | ≥0.34 | 12/12 | 12/12 | 0/12 |

Three things fall out.

1. **The two gates disagree in exactly one band, rms ≈ 0.0015 — and that band stored
   0/12 labels.** Every false label observed anywhere sat in a band 1.6.0's gate
   already admitted, so those false positives ship today and are not this change's
   doing. The premise that the change would admit confident nonsense is not
   supported.
2. **0.10 would cost real recordings.** Sustained quiet rain (rms 0.0045) peaks at
   0.070, and a 10 s quiet clip whose one clearly audible event peaks at 0.10 sits
   right on the line. Both would be rejected — and a rejection is written as the
   terminal "nothing to say" marker, so it is permanent.
3. **The old input really was unusable.** That same 10 s clip measures peak@32
   0.0112 and peak@56 0.0137 — *both under 0.02*, so 1.6.0 writes off a recording
   with an unmistakable sound in it, and the two call sites disagree besides.

`minimumPeak` stays at **0.02**. Codex and Gemini 3.6 Flash were consulted with the
measurements and independently reached the same conclusion, both rejecting the
scale-the-threshold argument on the grounds that the two statistics differ in
distribution, not by a constant.

**What the measurements did surface: `waterfall`.** Quiet broadband room tone is
spectrally close to running water, and the model says so at 0.30–0.38 — over the
global floor. "A waterfall" for a recording of an empty room is precisely what §1.2
forbids. Fixed with a **per-label floor** (`SoundVocabulary.elevatedConfidenceFloors`)
rather than a global raise, which would have cost every other label, or a removal,
which would have cost real waterfalls. `waterfall` → 0.45, above every false positive
observed. Calibrated against negatives only: known to remove these, not yet known to
preserve true positives.

### 11D. Open, from the same pass

| # | Issue | Note |
|---|---|---|
| 1 | **Window confidences are averaged over *all* windows** (`Collector.best()`: `sum / windows`). A sound present in part of a capsule is diluted by the rest of it — mechanically certain from the code, and the longer the capsule the worse | Raised independently by Gemini. **I could not demonstrate harm**: synthetic probes failed to isolate it, because the quiet portion of a tonal test signal still reads as tonal (`mean(present)` equalled `mean(all)` at every occupancy). Needs a real-audio corpus before changing the aggregate — a naive switch to `max` would trade dilution for one-window false positives |
| ~~2~~ | ~~The terminal "nothing to say" marker carries no gate version~~ | **Fixed** — see §11E |
| 3 | The confidence floor is one global number chosen to clear one measured artefact | `waterfall` is now the first per-label exception. Codex would go further: per-label calibration against a confuser corpus, and prefer one well-supported label over "up to three" |


### 11E. A verdict now records which gates produced it (2026-08-09)

Closes §11A#2 and §11D#2, which Codex and Gemini raised independently and from
opposite directions.

`1/version1|` means "we listened and had nothing to say". It is terminal on purpose:
the backfill only refetches `soundprintRaw == nil`, which is what stops it
re-examining the same silent clip on every launch forever. The cost is that a verdict
outlives the thresholds that produced it — and 1.6.0's were wrong in a way that
mattered. Its amplitude gate read a bucket average whose value moved with a
waveform-*drawing* parameter that differed per call site, so a quiet-but-audible
recording could clear the gate at capture, fail it during backfill, and be written
off permanently (§11C).

The stored form now carries a **gate generation** beside the schema version and the
classifier id: `<schema>/<classifier>[/<gate>]|<pairs>`.

| Decision | Why |
|---|---|
| **Gate 1 is written without the component** | Gate 1 *is* the format 1.6.0 shipped. One representation per (schema, classifier, gate), the values already in users' stores are byte-identical to what gate 1 would produce now, and the remediation pass can therefore find them with a plain equality predicate |
| The component is **optional on read**, absent ⇒ gate 1 | Rejecting `1/version1|…` would strand every capsule 1.6.0 analysed: `Soundprint(stored:)` would return nil while `soundprintRaw` stayed non-nil, so the capsule would look unanalysed *and* never be picked up again |
| **Only empty markers are reopened** | A stored label is evidence about the audio; a threshold change does not make it wrong, and re-analysing labelled capsules would churn the whole library for nothing. An empty marker is entirely a judgement call by the gates, so it is exactly what a gate change invalidates |
| Reopening = setting `soundprintRaw` back to `nil` | Hands the capsule to the ordinary backfill instead of adding a second analysis path to keep in step with the first |
| Bounded (40/launch) and consent-gated | Same reasoning as the backfill; and reopening is a prelude to analysing again, so it must respect the switch that says not to |

Gate **2** = absolute-peak amplitude input, per-label confidence floors. Bump it
whenever a gate changes in a way that could alter an empty verdict.

A first draft always wrote the gate component, so it looked for `1/version1/1|` and
would have matched **nothing at all** — the remediation would have run, reported
success, and silently reopened zero capsules. The test that pins the marker 1.6.0
actually wrote is what caught it.


### 11F. The Apple Intelligence sentence speaks the reader's language (2026-08-09)

Closes §11A#3, which had a §1.2 violation inside it.

`SoundSummaryWriter` had no language handling at all: English-only instructions,
English field labels in the prompt, and a refusal blocklist of seven English prefixes
matched with `hasPrefix`. On a Japanese device the model was steered to answer in
English and that sentence rendered directly above the user's own Japanese note. Worse,
a Japanese or Chinese *refusal* — "申し訳ありませんが…" — cleared every remaining guard
(non-empty, under 160 characters, no blank line) and displayed as if it described
their memory.

Three layers, all testable without Apple Intelligence, which the generation path
itself is not:

| Layer | What it does |
|---|---|
| **Language gate** | `availability()` returns `.unsupportedLanguage` unless the model speaks `Locale.current.language`, compared on language code with script honoured when both sides declare one — an exact `Locale` match would refuse `ja` against a model advertising `ja-JP`. No sentence beats an English one on a Japanese screen; the caller's own copy is already localized |
| **The brief** | A rule pinning the output language to the language of the facts, naming the failure it prevents so a future edit cannot quietly drop it |
| **Two output guards** | The refusal list now covers en/ja/zh-Hans. And `mentionsAGivenFact` — a refusal does not contain the user's place or the sound the classifier heard, in any language, whereas the sentence we asked for is built out of exactly those |

`mentionsAGivenFact` anchors only on sound phrases and the place: short localized
nouns, meaningful in scripts with and without word breaks. The note is deliberately
not an anchor — free text of any length, and a legitimate one-sentence rephrasing may
share nothing quotable with it. For a note-only capsule the check stands aside and the
blocklist is the whole defence, which is a limit worth stating rather than papering
over. Rejecting a good sentence costs a fallback to localized copy; accepting a bad
one breaks §1.2.


### 11G. External review pass — Codex + Gemini 3.6 Flash (2026-08-09)

Both reviewed the unreleased delta. Between them they found eleven defects, several
in reasoning I had written down as settled. What was accepted, what was not:

**Where my own argument was self-contradictory.** `SoundprintRemediation` reopened
only *empty* markers, on the stated grounds that "a stored label is evidence about
the audio; a threshold change does not make it wrong". The per-label floor added
hours earlier exists precisely *because* measured `waterfall` labels at 0.30–0.38
were wrong about quiet rooms — so a capsule carrying one from gate 1 would have kept
saying "a waterfall" forever, grandfathering in the §1.2 failure the floor was raised
to stop. Superseded capsules are now re-judged: labels that still clear today's gates
are **re-stamped** with the current gate (vetted without re-reading audio, and they
leave the candidate set so passes converge), and anything else is reopened.

**The `rain`/`train` bug, reintroduced in a new place.** `mentionsAGivenFact` used
`localizedStandardContains`, so the anchor `rain` matched inside "A train passed" —
the same substring trap this project already fixed for search (§4E / Codex F4). It
now uses `GalleryFilter.matches` for scripts with word boundaries. Not for CJK: there
the boundary rule degrades to "must start the sentence", and 「今朝は雨でした」 would
fail its own anchor 雨, which would switch the feature off for two of three shipped
languages rather than make it stricter.

**A guard that guarded nothing.** For a note-only capsule `mentionsAGivenFact`
returned `true` — no factual check at all — and a test locked that in. "You watched
fireworks together." was accepted against the note "the storm broke". The note now
supplies anchors (words for spaced scripts, two-character runs for CJK) and the
fallback is to reject.

**Language, checked rather than requested.** The gate proves the model *can* speak
the reader's language and the brief *asks* it to; neither looks at what came back,
and the place anchor is satisfied by a CJK place name sitting inside English prose.
`looksLikeTheSameScript` now strips the given facts out first and tests the script of
the model's own remaining prose — "A rainy afternoon in 東京." fails, as it should.
Also: Japanese models wrap output in 「corner brackets」, which the quote-stripper did
not remove, so `hasPrefix("申し訳")` never fired and the trilingual refusal list was
reachable only for unwrapped output.

**Consent ordering.** `.distantPast` adoption lost a genuinely newer opt-out: device A
records "on", the user later switches off on device B while it is still on 1.6.0, B
upgrades, finds A's record and stands aside — silently resuming listening against the
most recent thing the user did. A carried-over opt-out is now dated `.now` and does
not defer to an existing record, once per device. It can outrank a genuinely newer
grant, and that asymmetry is deliberate: forcing off wrongly costs one flick of a
switch, forcing on wrongly resumes analysing audio somebody opted out of. Separately,
`changedAt` is clamped to the present on read — a device with a fast clock could
otherwise pin listening on for as long as its clock was wrong.

**Failures that were only logged.** A failed consent write left `@AppStorage` already
moved, so the device acted on an answer that was never stored — and the dangerous
direction is turning listening back *on*, where the next launch resolves the
surviving "off" and erases labels created in between. The switch now writes through a
`Binding` that moves the mirror only after the record is durable, so a failed write
springs the switch back and says so. A failed erase alerts instead of logging
quietly, because that is the half of the sentence the footer promises by name. Both
`set` and the remediation restore their values by hand on failure rather than relying
on `rollback()`, which this project has already established does not restore
materialised objects.

**Declined, with reasons.**

| Finding | Why not |
|---|---|
| Split provenance from the right so a classifier containing `/` parses | Tried it; it made `1/version1/x\|rain=0.8` parse as the classifier "version1/x" **with real labels**, breaking the invariant the type is built on — corruption degrades to "never analysed", never to wrong labels. No `SNClassifierIdentifier` contains a slash, and if one did, degrading hands the capsule to the backfill, which is recovery. Reverted to the strict parse and pinned it with a test |
| `CloudKitSchemaTests` can't fail because `isStoredInMemoryOnly` disables CloudKit validation | Disproved by negative control before this review: removing the default from `ListeningConsent.enabled` fails it with the real Core Data message. Validation does run |
| The `#Predicate` cannot translate and silently fetches nothing | The fetch is `try?`, so a translation failure returns 0 — and the tests assert 2/2/1. They could not pass on a swallowed error |

**Still open**: the capture-suggestion tests set `soundprint` through a seam rather
than driving the real classification completion, so a regression written *inside* that
completion would still pass. Fixing it properly needs a classifier seam on
`CaptureViewModel`, which is a larger change than the rest of this pass.


### 11H. One launch settles the library, not fifteen (2026-08-10)

Closes §11A#4, which was attached to a claim already shipped: the 1.6.0 release notes
say *"Search 'rain' and your rainy mornings come back."*

The backfill did exactly one batch of twenty per launch. For a long-time user with
three hundred pre-M15 capsules that is roughly **fifteen separate launches** before
the sentence is true, and in the meantime search returns a partial set with nothing
saying so. The gate versioning added in §11E made it worse rather than better: the
remediation pass feeds the backfill, and it was bounded the same way, so a library
labelled under gate 1 waited for *both* to grind through forty and twenty a launch.

The bound was being read too literally. It exists for **memory** — one clip in flight
at a time, the M9 rule — and for not competing with capture. Neither requires stopping
after twenty. Measured cost is 0.02–0.05 s for a three-second clip, so three hundred
capsules is some tens of seconds of background work, once, because it converges.

Both passes now drain: batch, yield, repeat until nothing is left.

| Decision | Why |
|---|---|
| Batching stays | It is what keeps peak memory at one clip, and what gives the loop somewhere to yield instead of holding the actor for the whole library |
| A 250 ms pause between batches | Capture and the UI get the device back between batches; the drain is background work and should feel like it |
| `maximumBatches` is a **runaway guard, not a quota** | Hitting it logs "stopped at the batch ceiling with work remaining" rather than returning as if the library were settled. A silent cap reads as completion, which is the failure this milestone kept finding elsewhere |
| The remediation drain counts **touched**, not reopened | A library whose gate-1 labels all still stand touches capsules on every batch and reopens none. A loop keyed on reopenings alone would never decide it was finished — it is pinned by a test |
| Cancellation is honoured | The launch task can go away; a drain that ignored that would keep working for a screen nobody is looking at |


### 11I. Search works in Japanese and Chinese (2026-08-11)

Closes §11A#7, on the feature 1.6.0 leads with.

`GalleryFilter.matches` required a match to begin a word. In scripts without spaces
that degrades to "must begin the phrase", so a Japanese user searching さえずり found
nothing against 鳥のさえずり, and 流声 found nothing against 车流声. The doc comment
called this an honest trade-off. It was not a trade-off — it was the rule failing to
apply, described as if it had.

What the rule protects against does not exist in those scripts. `rain`/`train` is an
orthographic accident of Latin: a train is not a kind of rain. Checked against the
**actual shipped vocabulary** rather than assumed — every containment among the 52
Japanese phrases is morphological and semantically right:

    雨 ⊂ 雨だれ, 雷雨      風 ⊂ 風に揺れる葉      猫 ⊂ 猫がのどを鳴らす音
    虫 ⊂ 虫の音           笑い声 ⊂ 赤ちゃんの笑い声

Searching 雨 and finding thunderstorms is the right answer. So an ideographic query
matches anywhere in the phrase; a Latin query still has to begin a word, and a test
pins that loosening one did not loosen the other.

**One definition of "is this CJK".** Three had accumulated — the capture-suggestion
join, the summary writer's fact anchors, and now search — each written for its own
case and each slightly different. They are branching on the same fact and should
agree about it. `ScriptHeuristics` holds both variants the codebase genuinely needs,
with the difference stated: the join counts CJK punctuation (「朝の音、」 wants no
space after it), while deciding *which script something is written in* does not treat
a full stop as evidence.


### 11J. Wrap-up (2026-08-12) — 1.6.0 is live

**1.6.0 (build 12) released to the App Store.** `READY_FOR_SALE`, verified against
App Store Connect rather than assumed.

Two closing repairs, both turning a promise into something a compiler or a test can
hold to account.

**The Sentry guarantee is now a type.** `Diagnostics.info/notice` and
`SentryBootstrap.capture` took `String` with a doc comment asking callers to pass only
static, non-PII text. An audit checked all fourteen call sites, found them clean, and
correctly noted that one future interpolating call site would leak with nothing
beneath it. M15 sharpened that: the app now derives sound labels from someone's
recording, and `CaptureView` puts one into an `accessibilityLabel`. They take
`StaticString` now — the compiler will only build one from a literal, so an
interpolation or anything derived from a capsule does not compile. The single caller
that wanted dynamic detail (a CloudKit error *code*) got its own `notice(_:code:)`
door, kept narrow rather than widening the general case back to `String`, which is how
a rule like this usually dies.

**The capture-suggestion tests now drive the real arrival path.** They set
`soundprint` through a seam and asserted on `save(using:)`, which proves nothing about
the classification completion — a regression writing `note = …` *inside* it passed
every one of them. The seam moved to where the assignment actually happens
(`CaptureViewModel.classify`), and `awaitClassificationForTesting` lets a test assert
on what the completion did. Verified by negative control: injecting an auto-fill into
the completion fails the test in two places, where before it would have passed
silently. That rule — "nothing is ever filled in for you" — is stated outright in the
shipped release notes, so it deserved a guard that could fail.

**Left open, deliberately, with reasons rather than silence:**

| # | Item | Why it is not closed |
|---|---|---|
| §11D#1 | Window confidences are averaged over *all* windows, so a sound occupying part of a capsule is diluted | Mechanically certain from the code; I could not demonstrate harm. Synthetic probes cannot isolate it — the quiet part of a tonal test signal still reads as tonal, and `mean(present)` equalled `mean(all)` at every occupancy I tried. Switching to `max` without a real-audio corpus trades dilution for one-window false positives, which is not obviously the better trade |
| §11A#12 | The ASC privacy nutrition label was asserted unchanged, never verified | Server-side state no test or script here can read. It needs one human look in App Store Connect. The in-repo reasoning is sound — labels are user content in the user's own private database — but "probably right" is exactly what this milestone kept finding was not enough |
| §11B-i | `CD_ListeningConsent` exists in neither CloudKit environment | The device run was skipped. It is no longer a thing to remember: `build-upload-asc.sh` refuses to upload while Production is behind the shipping schema |


### 11K. 1.7.0 prepared, and stopped at its own gate (2026-08-13)

Everything for 1.7.0 is ready except the one step that cannot be taken from here.

Version 1.7.0 / build 13. Five bullets in three languages, 1.6.0's notes archived as
`release_notes-1.6.0.txt`. Clean build: **395 tests / 0 warnings / i18n 100% /
52 labels**. A Release archive builds and signs.

**Why it is not uploaded.** `build-upload-asc.sh` refuses while CloudKit Production is
behind the shipping schema, and `CD_ListeningConsent` exists in **neither**
environment. That gate is not incidental to this release — 1.7.0 is the release whose
headline is *"turn it off anywhere and it is off everywhere"*, and shipping it without
the record type in Production makes exactly that sentence false, silently, in the way
this milestone has spent its whole length learning to distrust.

Three ways past it were considered and rejected:

| Option | Why not |
|---|---|
| `CK_SKIP_SCHEMA_CHECK=yes` and upload | Ships a claim known to be false. The override exists for a human who has weighed it, not for an agent working around its own gate |
| Hand-author `CD_ListeningConsent` and import it | `CD_Capsule`'s export makes the conventions legible (UUID→STRING, Date→TIMESTAMP), so it is *probably* right — but it cannot be verified without the same device run it is trying to avoid, and Production never gives a record type back |
| Cut `ListeningConsent` from this release | The release then ships the amplitude-gate remediation and the CJK search fix without the consent work — defensible, but it means reverting a feature that was asked for, unwound across six files, while nobody is around to say whether that trade is wanted |

**The single unblocking step**, unchanged: run a development-signed build on a device
signed into iCloud, toggle Listening once, then `cloudkit-schema.sh promote` and
`build-upload-asc.sh`. All devices read `unavailable` today.


### 11M. The vocabulary, doubled where it was safe to (2026-08-17)

52 → **74 named labels**, 44 → **54 refused**. Apple's taxonomy has 303; 207 had never
been considered at all, which meant a great many ordinary sounds someone records had
no name, could not be searched, and could not be said.

**Method, because the method is the finding.** I wrote my own verdict on all 207
**before** reading any model's, precisely so the comparison would mean something —
the last external review caught a piece of my reasoning that was internally
consistent and wrong, and that only works if there is an independent position to
knock down. Then Gemini 3.7 Flash was asked the same question twice.

Three judgements converged on the same **22 labels**, and those are what shipped:

    thunder  wind_chime  pigeon_dove_coo  duck_quack  rooster_crow  cow_moo
    sheep_bleat  horse_clip_clop  cello  flute  saxophone  trumpet  harmonica
    accordion  harp  ukulele  orchestra  choir_singing  bicycle_bell
    train_whistle  sewing_machine  typewriter

**The two Gemini runs disagreed with each other**, which is the most useful thing
that happened. Run 1 recommended 44, run 2 recommended 28 — a strict subset — and
`lawn_mower` was recommended by one and explicitly refused by the other. `silence`
moved between "leave unset" and "refuse". So a single run's list is not a result; the
stable core is. That is now the rule: unanimous → take it, split → I decide and write
down why, appears once → not this release.

**What I refused, including one I changed my mind about.**

| Refused | Why |
|---|---|
| `silence` | The plainest possible way to tell someone their memory was something it wasn't. Left *unset* it reads as "not got to yet" and could be added back; refused, it cannot |
| `wind_noise_microphone` | Describes our equipment, not their room |
| `dog_growl`, `dog_whimper`, `dog_howl`, `coyote_howl`, `lion_roar` | The distress rule applies to the animals in someone's life too |
| `snicker` | Imputes derision to a person in the room |
| `door_slam` | **I had this in my recommend list.** A slammed door is far likelier to be an argument than a keepsake, and "a capsule is a keepsake, not surveillance" decides it |

**What I declined to take from the review.** Gemini proposed per-label confidence
floors (0.45 / 0.48 / 0.52) and safeguards like "require harmonic water modulation",
"multi-frame confirmation", "cross-check the confidence delta against `owl_hoot`".
The pipeline has a floor and an allow-list and none of that machinery, and the
numbers were reasoned rather than measured — `waterfall`'s 0.45 came from 14 levels ×
12 trials. §11C says do not add entries by intuition, measure them first; that applies
to me. So the acoustically fragile candidates — the `liquid_*` family, fans, air
conditioners, short transients like `click`/`tap`/`squeak` — are **not** in this pass.

**The size bound moved, deliberately.** §4D set 40–60 and a test enforced it. 74
breaks that, so the bound is now 40–90 with the reason recorded rather than the test
quietly edited: the cost the bound stands for is three hand-written translations per
label, which 74 does not strain and 303 would. It stays below the taxonomy so
exceeding it always costs an argument.

**Codex could not be obtained.** Two runs died at exit 144 with no answer, and the
transcript shows the second was reading the vocabulary *while I was editing it* — 11
mentions of labels added mid-run. Even a completed answer would no longer have been
independent. Its one surviving headline ("7 recommendations, 30 refusals") is not
used anywhere here: I never saw the reasoning behind it, and citing a number whose
argument you have not read is not much better than inventing one.


### 11N. Measured, and my caution was wrong (2026-08-17)

§11M held 42 candidates back for being "acoustically fragile — close to quiet room
tone": the whole `liquid_*` family, fans, air conditioners, hairdryers, and short
transients like `click`, `knock`, `zipper`. That judgement came from one case —
`waterfall` firing at 0.30–0.38 on room tone — generalised to a whole shape of sound.

Measured instead. 80 quiet-room clips (one-pole low-passed tone **and** broadband
hiss, rms 0.003–0.020, eight trials each) against the real `.version1` classifier:

| | fired on a quiet room | peak |
|---|---|---|
| `waterfall` *(control)* | **8 / 80** | 0.38 |
| all 42 candidates | **0 / 80** | — |

**The generalisation was wrong.** `waterfall` is not the first member of a risky
family; it is a one-off. Eighteen of the candidates are now named — dripping,
trickling water, a fan, a hairdryer, a blender, a microwave, a printer, a doorbell, a
drawer, keys, clinking glasses, a dropped coin, a zip, scissors, crinkling paper,
chopping wood, a knock, writing — and the vocabulary stands at **92**.

**The control is the reason the result is usable.** Forty-two labels firing zero times
looks exactly like a probe whose classifier call returns nothing. Carrying `waterfall`
in the watched set — a label already known to fire on this stimulus — is what
distinguishes "measured clean" from "measured nothing". It reproduced its earlier
8/80 at 0.38, so the probe could see a false positive when there was one.

`waterfall` remains **the only** label with a raised floor, and a test now pins that:
the others were measured clean and must not acquire invented thresholds. §11C's rule
— do not add entries by intuition, measure them — turned out to cut both ways. It
stopped a bad floor being invented, and it also showed that a cautious *exclusion* was
just as unmeasured as a careless inclusion.

Size bound raised a second time, 40–90 → 40–120, again with the reason recorded rather
than the test quietly edited. Still far below the taxonomy's 303.

---

### §11P — 1.7.0 release review: what the gates could not see (2026-08-23)

Three independent reviews of the 1.7.0 candidate (Codex, Gemini 3.7 Flash, and an
internal five-lens adversarial pass). The findings that survived verification are
below, with the two that did not, because a review is only useful if its misses are
recorded alongside its hits.

**1. Four user-facing strings shipped untranslated, and the localization gate could
not fail for it.**

`check-localization.sh` iterates the String Catalog and asserts every key is
translated into ja and zh-Hans. It has passed on every commit of M15. Meanwhile four
strings in `SettingsView` — both listening-error alerts and their messages — were
never *in* the catalog, so the gate never looked at them. Two shipped to users in
1.6.1 and 1.6.2; Japanese and Chinese readers saw English.

This is the M15 pattern again, in a new place: **a gate that iterates the artefact
cannot fail for something missing from the artefact.** It is the same shape as
`-only-testing:` on a suite that does not exist reporting `TEST SUCCEEDED` over
`Executed 0 tests`, and as `check-warnings.sh` passing on an incremental build that
recompiled nothing. Each time, silence read as success.

So the gate now reads the **source** rather than the catalog: every literal in a
localizing position (`Text`, `Button`, `.alert`, `String(localized:)`, …) must exist
as a catalog key, or the gate fails with a file:line. `Text(verbatim:)` is the
opt-out, which is what that spelling already meant. Confirmed against a control —
deleting one of the four keys turns the gate red and names
`SettingsView.swift:79`. A gate that has never been seen to fail is not evidence.

**2. A grant from a fast clock could undo a later withdrawal, minutes after the fact.**

`effectiveDate` clamps a future-dated `changedAt` to now, so a device whose clock runs
fast cannot pin listening on with a timestamp from next year. The clamp is computed at
read time, and that turns out to be the whole problem: it **expires**. Device A's clock
is five minutes fast and grants at its 12:05; at true 12:02 the user withdraws on
device B. Until 12:05 the clamp makes them tie and the tie-break honours off, exactly
as designed. At 12:06 the grant is no longer in the future, 12:05 beats 12:02, and the
next launch or merge turns listening back on by itself — and the backfill re-labels
the capsules the user had just cleared. The user switched it off, watched it go off,
and it came back.

The obvious fix is wrong and worth recording as such: **rewriting the future date down
to `now` makes it worse**, because "now" at the moment of noticing (12:02-and-a-bit) is
*later* than B's honest 12:02, so the grant wins sooner rather than never. Any single
timestamp we invent hands the record an ordering it has not earned.

So `settleFutureDatedAnswers` stops trying to order it. A device that dates an answer
into the future has told us its clock is unusable, and no later reading will make the
two orderable — which is precisely the case §1.2 already has a rule for: when two
answers cannot be ordered, take the one that says stop. It writes a single trustworthy
"off", making permanent the answer the tie-break was already giving before the clamp
expired. When every answer agrees there is nothing to arbitrate and only the date comes
back to the present.

The regression test was checked against a control: with settling stubbed out it fails
on exactly the assertion that matters (`winner(now: +1h)` returns the grant), and
`honestlyDatedAnswersAreNotTouched` stays green, so this did not quietly become an
off-latch.

**3. An adoption marked itself done even when its write had failed.**

`adoptPreAccountWithdrawal` set its one-shot flag in a `defer`, so a throwing
`context.save()` left the flag set and the record unwritten. The device itself still
honoured the local mirror, so nothing looked wrong — but the opt-out would never be
carried across on any later launch, and the next device the user added would find no
record, default to on, and analyse the library they had opted out of. That is the
exact failure the function exists to prevent, arriving through the function meant to
prevent it. The flag now means "the record was written", not "we tried".

**4. Chinese store metadata had drifted from the app's own standard.**

The app's 303 zh-Hans strings use full-width punctuation without a single exception.
The store metadata, which is edited outside the catalog, had seven half-width marks in
the 1.7.0 notes; 1.6.2 shipped with three. To a Chinese reader a half-width comma reads
as a listing nobody proof-read. Now gated, with `keywords.txt` excluded (its commas are
syntax App Store Connect parses) and archived `release_notes-<version>.txt` excluded —
correcting those would make the archive say something that was never true.

**Not confirmed.** Two findings did not survive checking, and both were plausible:

- *"`RemoteChangeReconciler` touches `mainContext` from a background thread."* It does
  not. The class is `@MainActor`, the observer registers with `queue: .main`, and the
  handler hops through `Task { @MainActor in … }`.
- *"The schema-seed `.task` sees a nil `store`."* `store` is a `let` on the view,
  assigned synchronously in `SoundpostApp.init`. There is no window in which it is nil.

A third was real in mechanism but wrong about the harm: an `eraseAll` failure does
leave the switch off with the labels still present, but `applyToDevice` erases
unconditionally whenever consent resolves off, so the next launch or merge repairs it.
The defect there is the copy, which asks the user to retry something the app will
retry by itself.

**5. One shared row meant CloudKit, not this code, decided which answer won.**

The largest correctness hole, and invisible from inside the type. `set` kept a single
row and updated it. Once that row has synced, both devices are editing the *same*
CKRecord, and `NSPersistentCloudKitContainer` resolves the conflict with its own
last-writer-wins before either version reaches `winner()`. The losing version is gone.
A device that was offline holding a stale "on" exports after a newer "off" has landed;
CloudKit keeps the "on" as the latest write to that record; the withdrawal disappears
with nothing left for `changedAt` to compare. Every careful line above it — the clamp,
the tie-break, the deterministic id ordering — was reasoning about a set of records
that, in the one case that matters, had already been reduced to one by someone else.

**An answer is now a row, and rows are never edited.** Separate records never conflict,
so each device's answer survives and `winner()` gets the full set. This also deleted
the collapse logic and, with it, the race where two devices picked different keepers
from an unordered fetch and deleted each other's rows — which could leave the account
with *no* consent record at all, falling back to precisely the per-device flag this
entity exists to replace. Rows stay bounded because an answer supersedes everything
strictly older; a newer answer from elsewhere is a newer row, which that never touches.

Worth noting the fields did not change, so this cost nothing against the pending
promotion — and would have cost a second one if found a week later.

**6. Two of the three release-note bullets described work that shipped in 1.6.1.**

`SoundSummaryWriter.swift` and `GalleryBrowsing.swift` do not appear in
`git diff release/1.6.2..master` at all. The Apple Intelligence language bullet and the
CJK search bullet were both already live and both already announced. Only the consent
bullet is new in 1.7.0. Announcing shipped work as new is the same category of untrue
statement as the privacy claims this project keeps correcting; the notes now say what
the build contains, including that a device applies the change on its next launch and
that a device still on an older version will not know about it.

**7. The App Store description contradicted itself, in all three languages.**

Line 12 said "your sounds stay on your device" while line 15 said capsules back up to
iCloud and sync across devices. The first is the same false claim already fixed in the
Settings footer and the release notes for 1.6.1 — it simply had not been fixed in the
listing, where far more people read it.

**8. And the finding that outranks everything above, which is not about 1.7.0 at all.**

`DeliveryIdentity` — a hand-rolled `CKRecord` type, not a SwiftData entity — exists in
CloudKit **Development but not Production**. Production is read-only from the client,
so in every App Store build since M10 the write fails, `currentUserKey()` returns nil,
and the app reads that as "signed out, use the local path" and says nothing. No APNs
token and no far-future seal job has ever reached the server from a shipped build.

Corroborated independently in the backend rather than inferred: `device_tokens` = 0
rows, `notification_jobs` = 0 rows, while `m10_send_due_notifications` has been running
every minute finding nothing. "Seal a capsule to open in five years" has therefore been
resting on a local notification — the 64-pending cap, lost on uninstall — which is the
exact durability risk M10 was written to remove. It is also why "Delete my cloud data"
fails for signed-in users with a misleading "check your connection".

**`cloudkit-schema.sh` could not have caught it.** It derived expected types only from
`Schema([...])`, prefixed `CD_`, so a record type the app builds with CloudKit's own
API was structurally outside what it checked — and it reported everything present for
months. That is the fourth instance of one shape in this review: *the gate iterates the
thing, so it cannot fail for what is missing from the thing.* It now also reads
`recordType = "…"` from source, and says `MISSING in Production: DeliveryIdentity`.

The repair is the step 1.7.0 is already blocked on. One dev-signed run with
`-initializeCloudKitSchema` then `promote` carries `DeliveryIdentity` and
`CD_ListeningConsent` together: a single device run fixes a months-old production
defect and unblocks the release. Afterwards, confirm with `status` **and** by watching
`device_tokens` gain rows — the emptiness of those tables is the only reason anyone
noticed, and it is the only end-to-end proof.
