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

### 4C. The schema tool begins with an experiment — and the premise was false

M17 §14D states that `cktool export-schema` omits unindexed fields, offering
`CD_soundprintRaw` as proof: it was missing from both exports while the CloudKit
Console listed it as a field to deploy. On that basis every gate built on the export
was written off, and §4C required an experiment before building anything on top of it.

**The experiment was run on 2026-09-05 and the conclusion is wrong.**

* **The export emits unindexed fields.** `Users.roles LIST<INT64>` and every metadata
  field (`"___createTime" TIMESTAMP`, `"___etag" STRING`, …) appear in both exports
  carrying no index annotation at all. That is a direct counter-example to the stated
  mechanism, visible in the checked-in artefact.

  A first draft of this section argued the weaker and wronger version — "every field
  carries an index annotation, so there are nothing unindexed to omit" — which is
  false of the same file it was arguing from, and an external review caught it. It is
  worth keeping the correction visible: an argument from *absence of instances* is
  exactly the move this project keeps getting wrong, and here there was a positive
  instance sitting twenty lines further down.
* `CD_audioData` is `BYTES` and is present, carrying `QUERYABLE SORTABLE` — so the
  externally-stored blob, the most plausible candidate for special treatment, is
  mirrored and exported like anything else.
* Read field by field against the CloudKit Console's own Development schema for
  `CD_Capsule`, the export matches **exactly** — the same fifteen record fields, the
  same index sets, the same six metadata fields, and the same one absent.

So the export **is** field-complete for what the server holds, and a Dev→Prod diff
built on it can be trusted. §14D should be read as corrected by this section.

**What actually happened in M17** is a different mechanism with the same symptom.
CoreData creates a Development field the first time a record carrying a value for it
is written; a field nothing has ever written does not exist server-side at all.
`CD_soundprintRaw` was genuinely absent from Development when M17 exported, and had
been created by the time the Console deploy was run. Not an export defect — an export
taken before the field existed.

The distinction decides what is worth building, and it is the opposite of what §14D
implied. A diff between two server environments cannot see a field the **app**
declares that neither environment has, because it is missing from both and the
comparison is symmetric. That is not hypothetical:

### 4C-i. `Capsule.serverJobSyncedAt` is not in the CloudKit schema. It never was.

`CD_Capsule` has fifteen fields in Development and the same fifteen in Production.
`Capsule` declares sixteen. The one the server has never heard of is
`serverJobSyncedAt` — M10 §4D's cross-device coordination flag, whose own doc comment
says it is "synced to the user's other devices via M9 CloudKit", and which
`NotificationPlanner` reads to decide whether a device may drop its **local**
notification backstop. It is the mechanism that makes exactly one notification fire
per resurfacing across a person's devices.

It has never been written a non-nil value — consistent with M10 far-future seal
delivery never having worked in a shipped build — which is precisely why CoreData
never created it.

**A first draft of this section called the consequence "latent, not live". That was
too comfortable, and the review that caught it was right.** The two preconditions for
the server path to complete are both already met in the field:

* `SupabaseDeliveryBackend.functionsURL` is a hard-coded live URL, so
  `backend.isConfigured` is **true in every shipped build**;
* `DeliveryIdentity` reached **Production on 2026-08-28**, so
  `identity.currentUserKey()` — the guard that used to make `reconcile` return early —
  now returns a key for any signed-in user.

So for a signed-in person with more than one device who seals a capsule more than 24h
out, the sequence is: device A registers the job and sets `serverJobSyncedAt`; device
A drops its local backstop; CloudKit **strips the field** because the schema has no
column for it; device B merges the capsule, sees `nil`, and inside the same
`NotificationCoordinator.sync` **schedules a local backstop first and reconciles with
the server second** — so it ends that pass holding both a queued local notification
and a redundant `upsert_job` it just sent for a job the server already had.

**A second review pass narrowed this, and the narrowing is worth keeping.** Device B
self-heals on its *next* sync: it has now set `serverJobSyncedAt` locally, so the next
`NotificationPlanner.plan` omits the seal, `scheduler.reconcile` sees the queued
request as stale and removes it. `refreshAndSync` runs on `scenePhase == .active`, so
opening the app once is enough.

What survives that correction is narrower and still real:

* **every** peer device sends a redundant `upsert_job` for a job the server already
  owns, once per merge, forever — there is no path by which `serverJobSyncedAt`
  reaches them, so each one re-derives it independently;
* a device that is **not opened between the seal being made and the seal falling due**
  still has the local backstop queued when the push arrives, and fires both. A second
  iPhone or an iPad that sits unopened for weeks is the ordinary case for a capsule
  sealed months out, which is the feature.

The delivery-time dedup M10 §4D added does not cover that last case:
`removeLocalSealRequests` runs from `willPresent` (foreground only) and `didReceive`
(the user tapped) — neither fires for a push arriving on a backgrounded device that is
not tapped. `apns-collapse-id` collapses pushes against pushes, not a push against a
local request.

`sealSignature` is deliberately not the fix for this. It hashes `id`, `state`,
`sealUntil` and `echoAt` — the fields that decide *when* a notification should fire —
and adding `serverJobSyncedAt` to it would make a device re-sync on its own bookkeeping
write. The fix is the field existing.

**What is genuinely unknown is whether the rest of the server path completes** — M18's
record says far-future seal delivery has never been confirmed end to end. If it still
fails somewhere else, `serverJobSyncedAt` is never set and nothing happens. That is
the honest position, and it cuts the other way too: **the field has to be deployed
before server delivery is confirmed working, or confirming it is what produces the
duplicates.** It belongs before the next release, not after.

Closing it needs a write of a non-nil value into Development and then a human deploy
in the CloudKit Console (§4G) — both owner-owned steps, now recorded in §8. Until
then it is in `CloudKitFieldCoverageTests.knownAbsent` as an **equality**, not an
allow-list: a second missing field fails, and so does this one being fixed without
the record being updated. A gap that can be forgotten is the shape this project keeps
rediscovering.

### 4C-ii. So the gate compares the app to the server, not the server to itself

`CloudKitFieldCoverageTests` derives the expected fields from the app's **runtime**
`Schema` — the same not-a-list discipline as M18 §4H's `ModelRegistrationTests`, which
reads the built binary rather than a hand-kept array — and compares them against a
checked-in export in `docs/cloudkit-schema/`. It runs offline, so it is in the suite
and in CI. `scripts/cloudkit-schema.sh check-fields` re-exports and fails if those
snapshots have drifted, so the thing the test reads cannot go stale silently.

Writing that subcommand produced one more instance of the family, in the tool itself:
`diff … | sed …` under `set -o pipefail` returns 1, so `set -e` aborted the function
**after** printing "drifted" and promising a refresh and **before** performing it. It
reported the problem and did not do the thing it said it would.

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

### 4D-i. Built, and seen — including the part that is not visible yet

The strip renders. Screenshotted on the simulator against the demo library: **On this
day** above a card reading **2025**, below "Coming up" and above the filter bar, absent
on every other date and absent while a filter is active.

**The sound line is missing from that card, and the cause is the §4A demo gap, not the
almanac.** `Almanac.line` asks `SoundprintDisplay.sentence(on: .card)`, which is gated
on `SoundAnalysisPreferences.mayReveal` — `isEnabled && hasStanding` — and
`hasStanding` is set at launch from `answered || hasRecordedHere`. A `-seedSampleData`
build has neither: no consent row was ever written, and nothing was ever *recorded* on
that install, because the library was **seeded**. So no surface in a demo build can
show a heard line, which is why the gallery's own note-less "Calm" card is blank too.

That is the gap §10 already names — "the demo library renders a 'Soundpost heard' line
on a clean machine, the claim `DemoData`'s comment already makes" — and S4 owns it.
Recording the mechanism here so S4 does not have to re-derive it: **a seeded demo
library is this install having a library**, and the `-seedSampleData` path should say
so. It is a launch-argument-gated DEBUG concern, not a change to what standing means.

The demo library also gained an anniversary capsule, dated with
`Calendar.date(byAdding: .year, value: -1)` rather than `-365 * 86_400` — because the
second one lands on the wrong day across a leap year, which is the exact rule this
feature exists to get right, and a screenshot would have been missing the strip for a
reason nobody would find.

### 4D-ii. Two things a review found, and the second is why S1 exists

**`DateComponents.year` is the year within an era.** The first implementation compared
`made.year < today.year` and subtracted them. The Japanese calendar is selectable in
iOS Settings, in this app's second language, and its years are era-relative: Heisei 30
read against Reiwa 8 is `30 < 8`, which is false, so the anniversary vanishes. It is
also a bug that *moves* — on the first day of a new era, every Reiwa recording would
disappear from the strip at once. It compares dates now, not integers.

Fixing that introduced a second one, which the test written for something else caught:
`dateComponents(from:to:)` counts whole years by the **clock**. A capsule made at 20:00
two years ago, read at noon, is two years minus eight hours and came back as one. The
test that found it was the one asserting the order of three capsules from a single
earlier day.

The obvious anchor for that — `startOfDay` — was a third bug, and it took a review to
see it. **Midnight does not exist everywhere on every day**: where DST begins at
midnight the clocks go from 23:59:59 to 01:00:00 and `startOfDay` returns 01:00 for
that date. Chile does this today; Brazil did until 2019. A capsule recorded on such a
day anchors at 01:00 against an ordinary anniversary's 00:00 — a year *minus* an hour,
which truncates to zero, and the `yearsAgo > 0` guard then drops the anniversary
entirely.

**The direction matters, and the first version of that test had it backwards.** With
the *viewing* day missing its midnight the arithmetic is a year and an hour, which
truncates to 1 and is right by accident; the test passed and proved nothing. It fails
only when the **capsule's** day is the one without a midnight. Both anchors are noon
now, which exists in every zone on every day.

**And the 64-slot guard was vacuous.** It built 88 anniversary capsules — none sealed,
none echoing — and asserted the plan contained only seals and echoes and fitted in 64.
The plan was the empty array: `allSatisfy` on nothing is true, `0 <= 64` is true, and
both assertions would have passed over an implementation that put an almanac entry in
every slot. The test even asserted `plan.isEmpty` and nobody read what that meant.

That is the sentence this milestone has now written four times — *a check that iterates
an artefact cannot fail for what is missing from the artefact* — and this time it was
in the test guarding the milestone's headline constraint, in the strand whose entire
job is to make such claims testable.

The replacement is a **baseline comparison at a full budget**: 70 sealed capsules, which
the planner caps to 64, then the anniversaries added on top, and equality over the whole
plan array. A mutation that lets a plain capsule take a slot is red.

**What that test does not prove**, since the first draft of this paragraph claimed it
did: it would pass identically if `Almanac` did not exist. What it guards is
`NotificationPlanner` — that nothing but a seal or an echo can reach the budget. The
almanac-specific half is structural, and it now scans the strip's **call sites** as
well as its policy, because the view is where a notification would actually be
scheduled from and scanning `Almanac.swift` alone left exactly that uncovered.
`ContentView` legitimately holds a `NotificationCoordinator`, so that one name is
allowed there and the other five are not.

Neither half can see a notification scheduled through some future indirection that
names none of those strings. Saying so is better than implying coverage that is not
there — the feature has no reason to schedule anything and no path towards one, and
the guard only has to make adding a path visible.

### 4B-i. The measurements (S1, taken 2026-09-05)

Recorded here because §10 asks for a number rather than a paragraph. iPhone 17
simulator, best of three, in-memory store. **The table is per call.** Each block is
timed as a repeated loop — 3, 5 or 200 iterations, enough to take tens of
milliseconds — and the figure below is that total divided by the count. The test's
own console output prints the same per-call figure; it used to print the loop total
under a per-call label, which made the lookup row look 200× more expensive than it is.

| Operation | small | large | ratio |
|---|---|---|---|
| `GalleryFilter.apply`, search active | 1,000 caps → **16.4 ms** | 4,000 caps → **65.3 ms** | **3.98×** |
| `SoundRejectionStore.index(among:)`, 3 answers/key | 3,000 rows → **6.8 ms** | 12,000 rows → **27.5 ms** | **4.04×** |
| `RejectionIndex.sounds(for:)` × every capsule | 1,000 → **0.12 ms** | 4,000 → **0.49 ms** | **4.16×** |

All three are linear. Every algorithm M18 §4B chose is the right one, and the lookup
it worried most about costs ~0.12 µs per capsule — the cheapest thing here.

**Two things an external review changed about how these were taken**, both of which
had made the first set less trustworthy than it looked:

* Blocks as short as **0.12 ms** were being timed. At that scale the "a ratio cancels
  load" argument fails: a scheduling slice is 5–10 ms, and a thread can move between a
  performance and an efficiency core between two samples. Either moves a
  sub-millisecond figure by more than the signal.
* `index(among:)` was measured with **one answer per key**, where
  `winner(amongRowsForOneKey:)` is `max(by:)` over a single element and returns
  *without calling the comparator*. The clamping, the ordering and the tie-break — the
  whole algorithm the row claims to time — never ran. Three answers per key now, which
  is also the shape a real library carries between compactions.

### 4B-ii. What the measurements were actually for

The three rows above say every algorithm was chosen correctly. The gallery was still
slow, and the reason had nothing to do with any of them.

`ContentView` exposed the resolved rejections as a computed property:

```swift
private var rejectionIndex: RejectionIndex { SoundRejectionStore.index(among: rejections) }
private var displayed: [Capsule] { GalleryFilter.apply(capsules, filterCriteria, rejecting: rejectionIndex) }
```

and its body read them like stored values — `displayed` three times (the empty check,
the sections, the animation value) and `rejectionIndex` **once per rendered card**,
inside the `ForEach`. Every card walked the entire rejection table. At 4,000 capsules
that is 27 ms per visible card plus three full filters, several hundred milliseconds
of main thread per body pass, and a keystroke triggers a body pass.

**Nothing in the suite could see it, and the reason is the interesting part.** M18 §4B
argued the case correctly and at length — resolution happens once in the gallery,
never per card — and the property's own doc comment restated it. The code did the
opposite for two milestones. The counters that were supposed to prove it counted
*fetches*, and the gallery holds its rejections in a `@Query`: it performs **zero**
fetches, so `theWholeTableIndexIsOneFetch` and
`theDisplayPolicyCostsNoFetchesPerCapsule` were both green over the broken
implementation. Resolution and reading are different costs. §4B promised a build count
as its own guard and S1 did not write one; that omission is what let this stand.

The fix is a value, not a smaller function. `GalleryPass` holds the index, the filtered
capsules, the sections and the anticipation strip as **stored** properties; `body` makes
one and hands it to the gallery, to the pushed detail screen and to the reveal cover;
and `ContentView` no longer names `SoundRejectionStore` at all. Reading a stored
property cannot recompute it, which is the property the old code lacked — it was not
written wrong, it read correctly at every use site, and that is exactly why nobody
saw it.

### 4B-iii. The same shape, twice more, found by looking for it

Once the pattern had a name, two more instances were sitting in the same file, and a
third review pass named them. Both were computed properties read from `body`:

| walk | when | 1,000 | 4,000 | ratio |
|---|---|---|---|---|
| `UpcomingResurfaces.sealSignature` | every body pass, via `.onChange` | **1.9 ms** | **7.8 ms** | **4.03×** |
| `UpcomingResurfaces.nearest` | twice per unfiltered pass | **2.5 ms** | **10.2 ms** | **4.13×** |
| `GalleryStorage.byteCount` | every gallery pass (the footer is not a lazy row) | **0.6 ms** | **2.4 ms** | **3.98×** |

Linear, and an order of magnitude below the filter — so neither was the emergency the
first one was, and saying so is the point of having measured rather than guessed.
Both are fixed anyway, because the fixes are smaller than the argument for keeping
them: `sealSignature` is a `Hasher` instead of one interpolated string per capsule
joined into a library-sized string that SwiftUI then compares on every pass, and
`upcoming` is a stored property on the pass, computed under the same condition that
decides whether the strip is shown — so the filtered case now pays nothing, where the
computed property paid twice.

`nearest` is also the second measurement in this milestone that was **timing nothing**.
The fixture stopped every capsule at `.captured` with no `sealUntil` and no `echoAt`,
so its `compactMap` produced no candidates and its sort ran over an empty array; the
figure above is 10.2 ms, against 6.1 ms for the version that found nothing. The fixture
now seals every 8th capsule and gives every 9th of the rest a future echo, which also
gives `Criteria.sealedOnly` and the hidden-content branch of `isContentVisible`
something to walk for the first time.

### 4B-iv. What is left, and what it costs

A body pass over 4,000 capsules with an active search now costs, in `GalleryPass.make`
alone, **~27 ms to resolve the rejections plus ~65 ms to filter — about 93 ms** — and a
keystroke is a body pass. Naming only the filter's 65 ms, as an earlier draft of this
section did, understates it by 40%. Adding the walks in §4B-iii that a filtered pass
still pays — the seal signature and the storage footer — the honest figure is
**~103 ms per keystroke at 4,000 capsules**.

The remaining per-pass walks that are *not* measured, because they are bounded rather
than linear: `upcomingCard` resolves each strip item back to its capsule with
`capsules.first(where:)`, at most three scans, and only on an unfiltered pass. Named
here so that "everything in this body was measured" is not claimed when it was not.

None of that is a regression; it is what walking a large library costs, and it is now
paid once per pass rather than three times plus once per card. But it is the honest
answer to "is the gallery fast enough at 4,000?": *not obviously*. Two §11 candidates
now have measurements behind them instead of hunches — debouncing the search, and
moving the gallery into a child view so that presenting a sheet or a `scenePhase`
change does not rebuild a pass that has not changed.

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

0. **Deploy `CD_Capsule.CD_serverJobSyncedAt`, before the next release** (§4C-i).
   The field the M10 cross-device backstop-drop depends on has never existed in
   CloudKit, and both preconditions for the server path to complete are now met in the
   field (`isConfigured` is a hard-coded live URL; `DeliveryIdentity` reached
   Production 2026-08-28). Two steps, both owner-owned:
   (a) make one signed-in device write a non-nil value — sealing a capsule more than
       24h out on a signed-in device is what does it — so CoreData creates the field
       in Development;
   (b) deploy Development → Production in the CloudKit Console (`cktool` has no
       deploy subcommand).
   Then `scripts/cloudkit-schema.sh check-fields`, and remove the entry from
   `CloudKitFieldCoverageTests.knownAbsent` — the suite fails until it is removed,
   which is deliberate.
1. **Release 1.8.0 when it is approved** — `python3 scripts/asc.py release`.
   `releaseType MANUAL`, unlike 1.7.0's auto-release: approved is not released.
   **Item 0 first**: releasing is not what arms the duplicate — the field being
   absent already does — but it is the moment more devices start running the path.
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
