# M19 — "What it is, and what it says it is"

> Soundpost has shipped three releases of a feature its own store page does not
> mention, and every performance claim in its codebase is an argument rather than a
> measurement. M19 closes both gaps, builds the tooling that stands between this
> project and any field-shaped feature, and adds the one item from M18 §11 a user
> would actually notice. Drafted 2026-09-04, with 1.8.0 in review.

---

## 0. Goal & success statement

Four strands, chosen together because they interlock rather than because they are a
list:

* **A — the store listing and screenshots.** Screenshots are from 1.1.0. The
  descriptions, in all three languages, describe an app that cannot recognise a
  sound, cannot be searched by one, and cannot be corrected.
* **B — a large-library fixture.** Nothing in the suite seeds more than 48 of
  anything, so `RejectionIndex`, `GalleryFilter` and the 20 Hz path have never been
  measured at a size a real library reaches.
* **C — a field-aware CloudKit schema check.** M18 §11: "the thing standing between
  this project and any field-shaped feature".
* **D — the acoustic almanac.** "A year ago today", from data the app already holds.

**Success:** the store page describes the app that exists; a performance claim in
this repository is a number someone measured; adding a *field* to a record type is
something the tooling can see; and a person opening Soundpost can be quietly shown
what a day sounded like a year ago, without being nagged.

**Not success:** screenshots hand-made once and stale again by 1.9.0; a wall-clock
assertion that reddens CI on a loaded machine; a schema tool built on an unverified
premise; an almanac that becomes a daily engagement loop.

### 0A. Why these four, and why together

They are not independent, which is the argument for one milestone rather than four.

1. **The screenshots need D to exist.** Photographing the app before the almanac
   ships means photographing an app that is about to change — the 1.1.0 set is what
   that produces. So A is sequenced *last*, and D is what it photographs.
2. **The screenshots need the DEBUG standing gap fixed.** The demo library renders
   no sound labels on a clean machine (`SoundpostApp.swift:216` sets
   `hasStanding` only on the `production` path; the `-seedSampleData` branch never
   runs it), so a screenshot build shows none of the differentiator. `DemoData`'s own
   comment already claims the opposite.
3. **D needs B.** The almanac competes for a fixed budget — iOS allows 64 pending
   notification requests and seals and echoes already share it
   (`NotificationPlanner.systemPendingLimit`). Deciding what the almanac may claim
   from that budget is a question about libraries with hundreds of capsules, which is
   exactly what B builds.
4. **C is the precondition for the milestone after this one.** `sealedAt`, and every
   other per-capsule field, waits on it.

### 0B. What this milestone deliberately does NOT do

- **No `sealedAt`, and no new field on any record type.** C builds the instrument;
  using it in the same milestone would mean shipping the thing the instrument exists
  to verify, verified by itself.
- **No new CloudKit entity**, therefore **no Console deploy**. D uses `createdAt` and
  `soundprintRaw`, both of which have been in Production since 1.6.0/1.7.0.
- **No orphan sweep.** Its price of entry is still an app-scoped recording lease that
  outlives the process (M18 §4E). Unchanged, uncut, unbuilt.
- **No identifier migration** (M18 §11).
- **No Pro lever**, no paywall, no new IAP. Free stays free.
- **No prompting, no counters, no streaks.** Especially not in D, which is the item
  on this list most likely to grow them.

---

## 1. Non-negotiables (carried from PROJECT.md / M9–M18)

1. **Never tell someone their memory was something it wasn't.** Applies to the
   almanac's copy and — newly — to screenshots, which are claims about the app.
2. A capsule is a keepsake, not surveillance.
3. **Shipped copy must be literally true.** A store listing and a screenshot are
   shipped copy.
4. Calm. No counters, no streaks, no engagement loops, no prompts.
5. Free stays free.
6. Offline-first. No new entity, no new field, no Console deploy this milestone.
7. Standing bars, every step: warning-free on Xcode 26, all tests green, i18n
   EN·JA·ZH-Hans 100%, zero new dependencies, CI green.

---

## 2. Scope

**In:** B the fixture · C the schema experiment and whatever it justifies · D the
almanac · A the listing and a repeatable screenshot path.

**Out:** `sealedAt` and any new field; the orphan sweep; identifier migration; App
Intents; a second correction surface; anything requiring a CloudKit deploy.

---

## 3. Current state (grounded — verified 2026-09-04, cite before you change)

| Fact | Where / evidence |
|---|---|
| Store screenshots are 1242×2688, captured **2026-06-10 for 1.1.0** | `screenshots/store/{en,ja,zh}/*.png`, commit `78c15f1` |
| There is **no screenshot tooling** of any kind | `grep -rl screenshot scripts/` → nothing |
| `asc.py` has **no** screenshot upload command | `grep -c screenshot scripts/asc.py` → 0 |
| **All three** descriptions omit listening, search and corrections | read in full; the two zh-Hans grep hits were 「听一次」/「听起来」, not the feature |
| `subtitle` is "Audio memories & voice journal" — pre-1.6.0 framing | `metadata/*/subtitle.txt` |
| `keywords` contains no sound-recognition term | `metadata/en-US/keywords.txt` |
| The largest fixture anywhere in the suite is **48** | `grep -oE "0\.\.<[0-9]+" SoundpostTests/` |
| 64 pending requests, shared by seal + echo | `NotificationPlanner.systemPendingLimit`, `Kind { seal, echo }` |
| The demo library shows no labels on a clean machine | `SoundpostApp.swift:216` vs the `isDemoSeed` branch at `:125` |
| `cktool export-schema` omits unindexed fields | M17 §14D — **but see §4C, this is now in doubt** |
| Production and Development schemas are byte-identical | verified 2026-09-01 after the M18 deploy |
| 1.8.0 is `WAITING_FOR_REVIEW`, `releaseType MANUAL` | `asc.py status`, submission `c3e8e40c` |

---

## 4. Architecture / design decisions

### 4A. Screenshots are shipped copy, and hand-made ones go stale by construction

The 1.1.0 set is the whole argument. Five screenshots, three locales, captured by
hand on 2026-06-10, and not touched through 1.3.0, 1.4.0, 1.5.0, 1.6.0, 1.6.1,
1.6.2, 1.7.0 or 1.8.0. Nothing failed; there was simply no step that could fail.

So A does not mean "take new screenshots". It means **a capture path that can be
re-run**, checked into `scripts/`, driving a simulator through the demo library and
writing the files the store wants. Re-running it is then a line in the release
checklist rather than an afternoon.

**Two things it depends on, and they are the reason A is not trivial:**

1. **The demo library must render the features.** Today it cannot: `hasStanding` is
   only ever set on the production launch path, so `-seedSampleData` shows no
   "Soundpost heard" line anywhere, and a screenshot build silently photographs the
   app as it was before 1.6.0. `DemoData.seed`'s own comment reasons at length that
   the fifth sample has no note *precisely so* the card shows the label — a claim
   that has been false on every clean machine since M17.
2. **A screenshot is a claim under rule 3.** It may only show states the app actually
   produces, from the real UI, with real demo data — never a mockup, never a state
   assembled for the photograph.

**Device sizes are a question to answer, not to assume.** 1242×2688 is the 6.5"
class; what App Store Connect currently *requires* versus *accepts* must be read from
ASC before the capture path is written, not guessed. Getting this wrong is a rejected
submission, not a cosmetic issue.

### 4B. The fixture must assert shape, not wall-clock time

The obvious form — "filtering 5,000 capsules must take under 200 ms" — is the wrong
one, and this repository already has the evidence. `VideoGateTests.playbackStaysFree`
and `VideoExporterTests.cancellingMidRenderStopsAndLeavesNoFile` fail locally for
environmental reasons; a neighbouring project building against the same simulator
once stretched a 2 s suite to 1500 s while every test still passed. A timing gate on
that machine is a coin flip, and a coin-flip gate gets disabled, which leaves the
thing it guarded unguarded.

So the fixture measures, and the *tests* assert properties that cannot flake:

- **Growth, not duration.** Filter 1,000 then 4,000 capsules; assert the ratio is
  bounded well below quadratic. A generous bound (say < 8× for 4× the input) catches
  an accidental O(n²) — which is the failure that actually matters — and is immune to
  a loaded machine, because both halves are slowed equally.
- **Fetch count, not fetch speed.** The §4B claim M18 makes is "one scoped fetch per
  operation, never one per capsule". That is a countable integer, and a counting
  wrapper around `ModelContext` turns it into an assertion. This is the strongest
  test in the strand: it pins the invariant M18 argued for in prose.
- **Index build count.** `RejectionIndex` is built once per gallery pass, not once
  per card. Also countable.
- Timings are printed as diagnostics so a human can see them, and asserted on by
  nothing.

**The fixture itself must not touch CloudKit.** `ModelConfiguration(isStoredInMemoryOnly: true)`
does not imply it — that defaulting is what exported twelve demo capsules into a real
person's iCloud on 2026-08-31 (`a3139db`). Every fixture container passes
`cloudKitDatabase: .none`, and `DemoDataIsolationTests` is the guard that already
exists for the same mistake.

### 4C. The schema tool begins with an experiment, because the premise is in doubt

M17 §14D states that `cktool export-schema` omits unindexed fields, and offers
`CD_soundprintRaw` as proof: `grep -c soundprintRaw` over both exports returned 0.

**That is no longer true.** On 2026-09-01 the same grep returns 1, and
`CD_soundprintRaw` appears in both exports carrying `QUERYABLE SEARCHABLE SORTABLE`.
Either the field gained an index during the M18 deploy, or the original diagnosis was
wrong about the mechanism. Nobody knows which, and the difference decides what can be
built:

- if the export omits **unindexed** fields, and CoreData+CloudKit indexes everything
  it mirrors on deploy, then a post-deploy export *is* field-complete and the tool is
  a straightforward derive-and-compare;
- if it omits fields for some other reason, no diff built on it can be trusted and
  the honest deliverable is a **recorded human confirmation** — a checked-in snapshot
  of what the Console showed, dated and signed off — rather than a script that
  pretends to know.

So **S2 starts by measuring**: add a field that CoreData will not index, export, and
look. Only then choose. Building the clever version first is precisely how §14D's
diff came to be presented as complete when it was not — and that mistake was made
while writing the section congratulating the project for catching such mistakes.

### 4D. The almanac shows up in the gallery, not on the lock screen

The feature is: *this is what a day sounded like a year ago*. The temptation is a
daily notification, and that is the version that must not ship.

**Two independent reasons, and the second is the load-bearing one:**

1. **Rule 4.** A daily "here's your memory" push is an engagement loop wearing a
   keepsake's clothes. This app has no counters and no streaks on purpose.
2. **The 64-slot budget is already spoken for.** iOS keeps 64 pending requests and
   drops the rest silently; seals and echoes compete for exactly that window
   (`NotificationPlanner`). **A seal is a promise the user made to themselves on a
   date they chose. An almanac entry is a nicety.** A nicety that can evict a promise
   is a defect, and with a large enough library it would — which is a claim §S1's
   fixture can now actually test rather than assert.

So the almanac is a **quiet strip in the gallery**, in the shape "Coming up" already
established (`ContentView.upcomingStrip`): present when there is something to show,
absent otherwise, and never a reason for the phone to light up.

**The rules it inherits, none of them new:**

- **Visibility.** A sealed-not-due capsule never appears — its sound is as hidden as
  its words (`isContentVisible`).
- **Attribution.** If the strip names a sound, it says who heard it
  (`SoundprintDisplay.sentence`), and it honours corrections
  (`RejectionIndex`) like every other surface.
- **Consent and standing.** `mayReveal`, as everywhere.
- **No clock invention.** "A year ago" is computed from `createdAt` against the
  device calendar, in the user's own time zone — the same honesty `SealClock` and
  `ResurfaceView.elapsedPhrase` already keep.

**What "a year ago today" means is a decision, not a given.** Exactly 365 days is
wrong across a leap year, and a library with no capsule on that date shows nothing —
which for a young library is most days. The rule is therefore *the same calendar day
in any earlier year*, and the strip is absent when there is no match. Absent is a
fine outcome; inventing a near-miss ("11 months ago") to have something to show is
the version that starts lying.

### 4B-i. The measurements (S1, taken 2026-09-05)

Recorded here because §10 asks for a number rather than a paragraph. iPhone 17
simulator, best of three, in-memory store:

| Operation | 1,000 | 4,000 | ratio |
|---|---|---|---|
| `GalleryFilter.apply` (search active) | 19.73 ms | 79.42 ms | **4.02×** |
| `SoundRejectionStore.index(among:)` | 3.25 ms | 13.06 ms | **4.02×** |
| `RejectionIndex.sounds(for:)` × every capsule | 0.12 ms | 0.52 ms | **4.19×** |

All three are linear. M18 §4B's argument survives contact with a measurement, and
`RejectionIndex` costs ~0.13 µs per capsule — the part that argument was most
worried about is the cheapest thing here.

**One number is worth carrying forward rather than celebrating.** Filtering 4,000
capsules with an active search takes ~79 ms, and `displayed` is a computed property
read from `body`. That is not a bug and not a regression — it is linear, and it is
the cost of walking a large library — but at that size it is a visible hitch per
keystroke, and it is the honest answer to "is the gallery fast enough at 4,000?":
*not obviously*. Nothing in this milestone changes it; a debounced or cached search
is a candidate for §11 now that there is a number to justify it instead of a hunch.

---

## 5. Work breakdown (sequenced; each step compiles + passes + commits)

**S1 — the fixture (§4B).** A seeding helper that builds thousands of capsules and
rejections in an in-memory, `cloudKitDatabase: .none` container; a counting
`ModelContext` wrapper; growth-ratio and fetch-count tests over `GalleryFilter.apply`,
`SoundRejectionStore.index` and the gallery's per-pass work. *First, because it is the
instrument the other three strands' claims rely on.*
*Tests:* filtering is sub-quadratic; one scoped fetch per operation; the index is
built once per pass, not once per card.
*Watch:* no wall-clock assertions. Print timings, assert shape.

**S2 — the schema experiment, then the tool (§4C).** Measure what `export-schema`
actually omits. Then either build the derive-and-compare gate or build the recorded
human confirmation, and write down which and why.
*Tests + control:* whichever is built, add a field and watch it go red.
*Watch:* do not skip the experiment. The premise is in doubt and the whole strand
rests on it.

**S3 — the almanac (§4D).** A pure `Almanac` policy (given capsules and a date, which
qualify), a quiet gallery strip, and the copy in three languages. No notification.
*Tests:* same-calendar-day matching across a leap year; a sealed-not-due capsule never
qualifies; consent, standing and corrections are all honoured; nothing is shown when
nothing matches.
*Watch:* the 64-slot budget is not touched — assert that the planner's output is
unchanged by the almanac's existence.

**S4 — the listing and the screenshot path (§4A).** Fix the demo standing gap; write
the capture script; regenerate all locales; rewrite `description`, `subtitle` and
`keywords` to describe the app that exists, including on-device listening.
*Last, because it photographs S3.*
*Tests:* the localization gate covers the new copy; a guard that the demo library
actually renders a label (the claim `DemoData` already makes in a comment).
*Watch:* device sizes read from ASC, not assumed.

**Drop order if tight:** S4's copy rewrite can ship without new screenshots; S2 can
stop after the experiment with the finding written down. **Never drop:** S1 before
S3 — the budget claim in §4D is the one thing that needs measuring before the almanac
is allowed to exist.

---

## 6. Privacy / legal delta

**No new data, no new entity, no new field, nothing new transmitted.** D reads
`createdAt` and `soundprintRaw`; B is test-only; C touches tooling; A touches text
and images.

**One thing changes in the other direction, and it is A.** The store listing
currently says nothing about the app analysing audio on device. The app itself
explains this carefully — the Settings footer names it in three languages, and 1.6.0's
release notes did — but the *store page*, which is where a prospective user decides,
is silent. That is not a false statement; it is the one surface where a
privacy-relevant capability is invisible to someone who has not installed yet. The
rewritten description says it plainly.

`PrivacyInfo.xcprivacy` unchanged — verify rather than assert. The ASC privacy
nutrition label remains open (M15 §11A#12, M18 §6) and is unaffected by this
milestone, which adds no category.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A timing test reddens CI on a loaded machine | §4B: growth ratios and counts, never durations |
| The fixture exports to a real iCloud | §4B: `cloudKitDatabase: .none`, and `DemoDataIsolationTests` already guards the shape |
| The schema tool is built on a false premise | §4C: measure first; the premise is already known to have changed |
| The almanac evicts a seal from the 64 slots | §4D: it is not a notification at all, and S1 makes that testable |
| The almanac becomes an engagement loop | §4D: gallery strip, absent when nothing matches, no push |
| A screenshot claims a feature the app lacks | §4A: real UI, real demo data, and the demo gap fixed first |
| Screenshots stale again by 1.9.0 | §4A: a re-runnable script, not an afternoon |
| Wrong screenshot dimensions → rejected submission | §4A: read the requirement from ASC before writing the capture path |
| A performance claim stays an argument | §10: the acceptance criterion is a number, not a paragraph |

---

## 8. Human-in-the-loop checklist (needs Jason)

1. **Release 1.8.0 when it is approved** — `python3 scripts/asc.py release`.
   `releaseType MANUAL`, unlike 1.7.0's auto-release: approved is not released.
2. **Production sync for corrections is still unverified** (M18). Two TestFlight
   devices, three minutes. If it fails, the 1.8.0 release note promising corrections
   follow iCloud must be corrected in 1.9.0.
3. **Screenshot upload.** `asc.py` has no command for it; either it gains one in S4 or
   the files are uploaded by hand. A decision, not a discovery.
4. **The two `MISSING_METADATA` IAPs** — `unset ASC_APP_ID` first (M17 §14F).
5. **The ASC privacy nutrition label** — still unread server-side state.
6. **Two inert CloudKit seed rows** remain in Development's private database.

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| A quiet gallery strip that is absent when empty | `ContentView.upcomingStrip` |
| Attributed copy for a heard sound | `SoundprintDisplay.sentence(for:on:rejecting:)` |
| Corrections applied at a display site | `RejectionIndex` / `RejectedSounds` |
| Consent + standing as one rule | `SoundAnalysisPreferences.mayReveal` |
| Visibility of a sealed capsule | `Capsule.isContentVisible(now:)` |
| Honest elapsed-time phrasing | `ResurfaceView.elapsedPhrase`, `SealClock` |
| A schema expectation derived from source | `cloudkit-schema.sh` `schema_entities` / `declared_models` |
| A guard that reads source rather than behaviour | `DemoDataIsolationTests`, `SoundprintNeverLeavesTheApp` |
| A demo library with per-locale strings | `DemoData.seed` |

---

## 10. Acceptance criteria

- The store description, subtitle and keywords describe listening, search and
  corrections, in all three languages, and say the analysis is on-device.
- Screenshots are regenerated **by a script that can be re-run**, and show the
  current app.
- The demo library renders a "Soundpost heard" line on a clean machine — the claim
  `DemoData`'s comment already makes.
- **A number exists** for filtering and index-building at 1,000 and 4,000 capsules,
  recorded in the plan, and a test fails if growth turns quadratic.
- "One scoped fetch per operation, never one per capsule" is an assertion, not a
  paragraph.
- Either a field-aware schema check exists, or the reason no CLI can provide one is
  written down with the measurement that shows it.
- The almanac shows a matching capsule from an earlier year, honours visibility,
  consent, standing and corrections, shows nothing when nothing matches, and **adds
  no notification requests**.
- Standing bars green at every commit. **No new record type, no new field, no
  CloudKit deploy.**

---

## 11. Out of scope / next

- **`sealedAt`** — the first customer of S2's tooling, deliberately not in the same
  milestone that builds it.
- **The orphan sweep**, still waiting on an app-scoped recording lease (M18 §4E).
- **Identifier migration** for rejections (M18 §4A).
- **An App Intent for capture.**
- **A correction affordance somewhere more discoverable than a long press** — M18
  shipped with essentially zero discoverability by design, and the release notes are
  currently the only place that says the feature exists. Worth revisiting once there
  is evidence about whether anyone finds it.
