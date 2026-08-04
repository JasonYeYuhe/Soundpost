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

> ## Status: **S1–S7 IMPLEMENTED** (2026-08-04)
>
> **322 tests / 0 warnings / i18n EN·JA·ZH-Hans 100% / 52 sound labels translated /
> zero new third-party deps**, CI green, deployment target still **iOS 17.0**.
>
> | Step | Commit | What it turned out to be about |
> |---|---|---|
> | S1 — service + model field | `3662650` | the *gates*, not the model: silence classifies as `music 0.25` |
> | S2 — vocabulary | `b5b2f14` | 52 labels named, **45 refused**; a new CI gate for the copy |
> | S3 — capture suggestions | `d59a2b1` | suggest a line, never a mood |
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
> **Not yet released.** 1.5.0 (M14) is still `WAITING_FOR_REVIEW`, and ASC allows one
> version in the pipeline — `asc.py` now refuses to touch a version in Apple's hands,
> so M15's release waits for that to clear.

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
