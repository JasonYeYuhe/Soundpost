# M17 — "What your life sounds like"

> Give people back what Soundpost already heard — visibly, honestly, and as a way to
> find things. Drafted 2026-08-25; **§4B overturned the same day** by review, and the
> plan rewritten around it. §12 records what the reviewers found.

---

## 0. Goal & success statement

Soundpost runs a 93-label on-device classifier over **every** recording, curates a
display phrase for each label in three languages, gates it behind account-wide
consent, backfills the whole library, and repairs stale verdicts on a gate bump.
Then it shows the result **in one place, for about four seconds**: a chip row on the
capture sheet before you save (`CaptureView.swift:217`). After that it is gone.

Grep confirms it: `Soundprint` and `SoundVocabulary` appear in `SettingsView`,
`ResurfaceView`, `CaptureView` and `CaptureViewModel`, and **nowhere** in
`CapsuleCard.swift`, `CapsuleDetailView.swift`, `CapsuleEditSheet.swift` or
`ShareCardView.swift`. For a long-standing user, *most* of their labels were written
by `SoundprintBackfill` on some launch — they were never on screen at all, and no
screen in the app can ever render them.

The one place the labels do reach is search, which no user has been told about: the
App Store description does not mention search, and `keywords.txt` has not changed
since 2026-06-09.

**Success:** you can see what Soundpost heard on any capsule, in your language,
attributed as a guess; one tap finds every other capsule that sounded like it; and a
recording in progress cannot be destroyed by a stray swipe.

**Not success:** new Pro levers, a "capture today" nag, a new `Capsule` field, or a
correction affordance whose durability we cannot honestly claim (§4B).

### 0A. Why this, and why now

1. **It is the differentiator, and it is currently invisible.** PROJECT.md §1a's
   central finding is that *no app pairs sound + mood + place + waveform-card*, and
   §1c's hook is "capture ten seconds of how your life actually sounds". The classifier
   is the "how your life sounds" half. Shipping it and then hiding it is the largest
   gap in the product between what it does and what a user gets.
2. **It needs no CloudKit schema change** — `soundprintRaw` already exists on
   `Capsule` and already syncs (`Capsule.swift:57`). The two human CloudKit steps from
   M15 §11R are still outstanding, and a milestone that needed a promotion would
   inherit that block. M16 proved the pattern; M17 follows it.
3. **M16 opened the door this milestone walks through.** Editing shipped, so a person
   can now fix a note. What they still cannot fix is the *label* the note was
   suggested from — and after the §4B review, they still won't be able to in M17.
   §4B is where that is argued rather than glossed.

### 0B. What this milestone deliberately does NOT do

- **Per-label rejection.** Overturned by review. §4B.
- **Deleting orphaned audio files.** The leak is real and gets *observed* in S0, not
  swept. §4E.
- **Pro.** Both products' last recorded ASC state is `MISSING_METADATA`
  (`docs/M11-DEVPLAN.md:560`); `Product.products(for:)` returns empty without throwing,
  so the paywall shows "Plans aren't available right now" with a retry that can never
  succeed (`StoreService.swift:91`, `ProPaywallView.swift:164`). **This is one human
  hour in App Store Connect, not code.** §8.
- **Far-future cloud delivery.** Never run in production; `DeliveryIdentity` is in
  CloudKit Development only (M15 §11P #8). Blocked on the same human step.
- **The gallery-performance milestone.** Already scoped as its own (M16 §11).
  `DemoData` seeds five capsules; there is no large-library harness, so a change made
  here would be unmeasured. §2 keeps one narrow exception.
- **The store listing.** No mention of listening or search, screenshots from the 1.1.0
  app, and one line that is false in shipped builds. Gated on a release train gated on
  the promotion. §8.
- **A "capture today" reminder.** Every notification kind today is retrospective by
  construction, and the gallery's own design note is "no counters, no engagement
  loops" (`ContentView.swift:178`). That is a decision for Jason (§8), not a step to
  build and argue about afterwards.

---

## 1. Non-negotiables (carried from PROJECT.md / M9–M16)

1. **Never tell someone their memory was something it wasn't.** This milestone puts a
   machine's guess onto a person's own keepsake. §4A is the whole answer, and it is
   load-bearing rather than decorative now that §4B removed the correction.
2. **A capsule is a keepsake, not surveillance.**
3. **Shipped copy must be literally true**, including a label rendered beside
   someone's own words.
4. **Calm.** No counters, no streaks, no engagement loops.
5. **Free stays free.** M15 recorded "sound understanding ships free" as a one-way
   door. Everything here is free.
6. **Offline-first, on-device. No new CloudKit field, no new entity, no promotion.**
   If a step seems to need one, stop.
7. **Standing bars, every step:** warning-free on Xcode 26, all tests green, i18n
   EN·JA·ZH-Hans 100%, zero new dependencies, CI green.

---

## 2. Scope

**In:** S0 protect the recording · S1 integrity of what Soundpost heard · S2 the label
made visible · S3 find others that sounded like this · S4 the honesty sweep.

**Out, deliberately:** everything in §0B, plus any new `Capsule` field or entity
(favourites, tags, collections, `sealedAt`, per-capsule appearance, rejection rows), a
new app-extension target (widget, Control Center control — each needs an App Group and
breaks the file-system-synchronized-group property the `.xcodeproj` relies on), and
re-recording / trimming / editing `createdAt` (M16 §2, unchanged).

**One performance exception.** `sealSignature` (`ContentView.swift:332`) builds a
string per capsule and joins the library on every body pass purely to feed an
`onChange`. If S3 touches that code path anyway, fixing it is in scope; hunting the
other seven walks is not.

---

## 3. Current state (grounded — cite before you change)

Verified against `master` @ `fcec040`, 1.7.0 / build 16, 440 tests in 56 suites green.
**Every citation in this table was independently re-checked by two reviewers and found
accurate** (§12); if you find one that is wrong, that is a finding worth recording.

| Fact | Where |
|---|---|
| 93 labels, all translated ja + zh-Hans | `Models/SoundVocabulary.swift`; `./scripts/check-sound-vocabulary.sh` |
| A label reaches the UI in exactly one place, pre-save | `Capture/CaptureView.swift:217` |
| No card / detail / edit / share view references `Soundprint` | grep over `Views/` |
| The stored form, and that it syncs | `Models/Soundprint.swift:16`, `Capsule.swift:57` |
| Empty ≠ nil: "listened, nothing to say" vs "never analysed" | `Soundprint.swift:21` |
| `isEmpty` is `labels.isEmpty` — it counts labels, not *displayable* ones | `Soundprint.swift:144` |
| `isAllowed` is a vocabulary-membership test | `Models/SoundVocabulary.swift:178` |
| Backfill selects on the **column** (`soundprintRaw == nil`) | `Services/SoundprintBackfill.swift:106` |
| Remediation's fetch is a **prefix test** hard-coded to `"1/version1\|"` | `Services/SoundprintRemediation.swift:39`, `:122` |
| Remediation revalidates survivors against today's floors before restamping | `SoundprintRemediation.swift:63` |
| `Soundprint(classifier:labels:)` defaults `gate` to **today's** gate | `Soundprint.swift:72` |
| Withdrawal erases every soundprint to `nil` (= never analysed) | `Services/SoundprintEraser.swift:30` |
| Search is consent-gated **and** visibility-gated | `Services/GalleryBrowsing.swift:56`, `:70` |
| **Bulk export is NOT consent-gated** — reads `soundprintRaw` unconditionally | `Services/CapsuleBulkExporter.swift:150` |
| Filter criteria are exactly search text, moods, sealed-only | `GalleryBrowsing.swift:13` |
| `Digest.lead`'s precedence: note → place → soundprint | `Services/NotificationCopy.swift:29` |
| `AudioRecorder.cancel()` exists and has **zero callers** | `Audio/AudioRecorder.swift:116` |
| `discard()` never touches the recorder; `fileName` is nil while recording | `Capture/CaptureViewModel.swift:185`, `:110` |
| The audio file is created at record **start**; the `Capsule` row only at **save** | `AudioRecorder.start`, `CaptureViewModel.swift:219` |
| The capture sheet has no `interactiveDismissDisabled` | `ContentView.swift:70` |
| Nothing enumerates the audio directory — an orphan is invisible | `Services/AudioMigrator.swift:57` |
| Notification authorization is read in exactly one place; no view reads it | `Services/Delivery/SoundpostAppDelegate.swift:30` |
| `seal(until:)` normalizes unconditionally; `normalizeSealHours` guards `> now` twice | `Services/CapsuleStore.swift:100`, `:255` |
| `pendingDeepLinkCapsuleID`'s only consumer is `.onChange` | `ContentView.swift:100` |
| The "Coming up" strip is not tappable | `ContentView.swift:195` |
| **CloudKit conflict resolution is record-level, and this repo learned it** | `Services/ListeningConsentStore.swift:136` |
| `cloudkit-schema.sh promote` exits 0 **before** the importer on a field-only delta | `scripts/cloudkit-schema.sh:176` |
| There is still no UI-test target | `Soundpost.xcodeproj/project.pbxproj` |

---

## 4. Architecture / design decisions

### 4A. A label is a guess, and the UI must say so in its own shape

Putting the classifier's output on a capsule makes the app **assert, permanently, in
the user's own gallery,** that their memory was rain. That is rule 1, and it is exactly
the argument that made three reviewers reject M16's first draft (M16 §0A). With
per-label correction deferred (§4B), these rules are the only protection there is —
they are not styling.

1. **Attribution is in the copy.** "Soundpost heard" — the sentence names the guesser.
   Never a bare noun sitting where the mood sits.
2. **The machine's guess never sits above or beside the user's own words.** On the
   card it appears **only when the capsule has no note**: it fills a silence, it does
   not compete. This is `NotificationCopy.Digest.lead`'s precedence (note → place →
   soundprint, `NotificationCopy.swift:29`) applied to a second surface — an already
   reviewed rule, reused rather than reinvented.
3. **It never reaches anything that leaves the app.** Not the share card, not the
   video, and never the note. The one existing door into the user's permanent words
   stays exactly where M16 left it (`CaptureView.acceptSuggestion`, deliberate, opt-in,
   and now editable).
4. **A sealed-not-due capsule shows nothing.** The sound is as hidden as the words;
   `isContentVisible(now:)` is the same gate the card body, the search index and M16's
   playback control already use.
5. **Display is consent-gated, exactly as search is.** `GalleryFilter` threads
   `listening:` for the case the app ships user-facing copy about — an erase that lags
   or fails. A rendering path that skipped it would surface the sound Soundpost heard
   on a device where the user turned listening off.

### 4B. Where a rejection would be stored — and why it is not in this milestone

**This section was rewritten after review. The original proposal was overturned.**

The plan proposed storing a rejected label as a tombstone inside `soundprintRaw` — the
identifier prefixed with `-`, at confidence 0 — to avoid the blocked CloudKit
promotion. Two of three reviewers rejected it; the third endorsed it on a premise that
turned out to be false. The premise, and its refutation, are the whole of this section
because the next person to want this feature will reach for the same idea.

**The premise: that CloudKit merges field-by-field**, so a stale device editing a
`note` could not clobber another device's `soundprintRaw`. **It does not.** This repo
already established that, at cost, in a comment written after the same mistake:

> "once a single row has synced, both devices are editing the *same* CKRecord, and
> `NSPersistentCloudKitContainer` resolves that conflict with its own
> last-writer-wins before either version reaches `winner()`. The losing version is
> simply gone." — `ListeningConsentStore.swift:136`

That is why `ListeningConsent` was rebuilt from one mutable row into immutable
append-only rows. A rejection stored in `soundprintRaw` has **the identical failure
mode**, and it is worse in kind than the one M16 accepted: two devices editing a
`note` lose one version of *something the user typed*, which the user can see and
redo. Here a stale **machine guess** silently overwrites an explicit **user
rejection** — the wrong label comes back, on its own, with no event the user can
attribute. That is rule 1 failing quietly, which is the worst way for it to fail.

Three further breakages were found in the code, and all three check out:

- **A gate bump strips every tombstone.** `rejudge` keeps only labels passing
  `SoundVocabulary.isAllowed` and the confidence floor
  (`SoundprintRemediation.swift:63`). `isAllowed("-wind_rustling_leaves")` is false
  (`SoundVocabulary.swift:178`) and `0.00 < floor`, so tombstones are filtered out; a
  fully-rejected capsule yields an empty `surviving`, is reopened to `nil`, and
  `SoundprintBackfill` re-analyses and resurrects every rejected label.
- **A consent off/on cycle wipes them.** `SoundprintEraser` writes `nil`
  (`SoundprintEraser.swift:30`), and the backfill then re-analyses from scratch. (This
  one is arguably *correct* — the user asked the app to forget what it heard — but it
  must be stated, not discovered.)
- **`isEmpty` would lie.** `labels.isEmpty` is false for a fully-tombstoned value, so
  `CaptureView.swift:217`'s `!soundprint.isEmpty` renders a "Sounds like" header over
  zero chips. §4C fixes this independently, because it is already reachable today.

**No third encoding exists.** The constraint set is over-determined: `UserDefaults`
gives durable-but-device-local; anything inside `soundprintRaw` gives synced-but-lossy;
immutable rows give both and need the blocked promotion. The adjudicating reviewer
looked for one and reported there is none.

**So M17 ships the labels without a per-label correction, and says so plainly.** The
rule-1 obligation is met instead by §4A — attribution in the copy, never above the
user's own words, never leaving the app, never on a sealed capsule, always
consent-gated — plus the account-wide switch that already exists and already erases
everything. **Rejection is M18's first item, behind the promotion, as immutable
`SoundRejection` rows** (`capsuleID`, `identifier`, `rejectedAt`), which is the shape
`ListeningConsent` already proved.

If you are implementing this and you find yourself reaching for the tombstone anyway:
re-read `ListeningConsentStore.swift:133–150` first.

### 4C. `isEmpty` counts labels, not the ones anyone can see

`Soundprint.isEmpty` is `labels.isEmpty` (`Soundprint.swift:144`). A stored value can
hold a label that is no longer in the vocabulary, or one below a floor that has since
been raised — both real, because the vocabulary grew from 52 to 93 and floors moved
twice. Such a value reports non-empty while every display path, which filters through
`SoundVocabulary.displayName`, renders nothing.

Today that costs one ghost section header in the capture sheet. After S2 it would cost
one on every surface that shows a label. So `Soundprint` grows an explicit notion of
what is *showable* — the labels that are in the vocabulary and clear today's floor —
and every render site asks that question rather than `isEmpty`.

### 4D. Consent gates the export too

`CapsuleBulkExporter` reads `snap.soundprintRaw` unconditionally
(`CapsuleBulkExporter.swift:150`) with no `SoundAnalysisPreferences` reference anywhere
in the file, while search threads `listening:` for exactly the case the app ships
user-facing copy about. An export taken in that window writes the sounds Soundpost
heard for a user who turned listening off, into a file they keep.

Small, a privacy defect rather than a feature, and it belongs here because this
milestone is about that data.

### 4E. A recording in flight must survive a swipe — and the sweep that would fix the debris is more dangerous than the debris

`AudioRecorder.cancel()` has **zero callers** in app or tests
(`AudioRecorder.swift:116`). `CaptureViewModel.discard()` stops the *player*, deletes
`fileName` — which is nil during `.recording`, since it is only assigned in
`handleFinishedRecording` — and calls `reset()`. Nothing stops the recorder. So a
sheet dismissed mid-take leaves `AVAudioRecorder` running, never reaches
`finishSession()` (the only place the meter timer is invalidated and the audio session
deactivated), and orphans an `.m4a` that **nothing in the app can ever see**:
`AudioMigrator` fetches `Capsule` rows and filters `audioFileName != nil`, and the
storage footer estimates from `durationSeconds` rather than reading the directory.

The capture sheet also has no `interactiveDismissDisabled` (`ContentView.swift:70` —
the app's only occurrence is in `OnboardingView`, where it is a no-op because
onboarding renders inline rather than as a sheet). So the swipe is one gesture away at
all times.

**The draft proposed a directory-enumerating sweep to reclaim the debris. Both
reviewers independently called it the most dangerous item in the plan, and they were
right.** The audio file is created at record *start*; the `Capsule` row is not
inserted until save (`CaptureViewModel.swift:219`). A sweep that deletes files no
capsule points at — exactly what the draft told the implementer to do — **deletes the
user's recording out from under the running `AVAudioRecorder`**, and a test that drops
a stray file next to a saved capsule passes green without ever simulating a take in
flight.

So M17 **stops the leak and does not clean it up**. S0 adds a read-only count of
unreferenced files at launch, logged through `Diagnostics`, so the leak becomes
observable at all — the §11P move, since a check that iterates capsule rows cannot
fail for a file no row points at. Deletion is M18 work, and when it is written it needs
*both* guards: unreferenced **and** untouched for a generous age window, **and** never
the recorder's current file.

### 4F. Do not let this milestone become a schema change

`cloudkit-schema.sh promote` computes the added **record types** and, when that set is
empty, prints `Nothing to do — Production already matches.` and `exit 0` at line 176 —
**before** `cktool import-schema` at line 186. `types_in` greps `RECORD TYPE` and keeps
`$3`; field lines are discarded. Four checks plus `CloudKitSchemaSeed`'s
`where entity.name != "Capsule"` are field-blind.

So a field-only change is not merely unverifiable — it **cannot be promoted at all**,
and the failure prints a success message. If any step here starts to want a field, that
is the signal to stop, not to work around. (Fixing the tooling is M18's price of entry
for the rejection rows.)

---

## 5. Work breakdown (sequenced; each step compiles + passes + commits)

**S0 — protect the recording (§4E).** Wire `cancel()` into the discard path;
`interactiveDismissDisabled` while a take is in flight; confirm before throwing one
away. Add the read-only orphan **count** at launch. **Delete nothing.**
*First, because the rest of this milestone invites people to record more.*
*Tests:* cancelling mid-record stops the recorder and finishes the session (meter timer
invalidated, session deactivated); the discard path is reachable from the `.recording`
phase at all; the orphan count reports a file no capsule references and does not count
one that is referenced.
*Watch:* `interactiveDismissDisabled` cannot be unit-tested here — no UI-test target.
Say so; do not imply coverage. Verify it by hand in the simulator and record that.

**S1 — integrity of what Soundpost heard (§4C/§4D).** No UI. Consent-gate the bulk
export. Give `Soundprint` an explicit showable-labels notion and move every existing
render site onto it. Make remediation gate-aware: `legacyPrefix()` hard-codes
`"1/version1|"`, so **no gate-2 verdict can ever be reopened** and a gate-3 bump would
strand every capsule analysed under gate 2, silently.
*Tests:* an export with listening off carries no soundprint; a value holding only
out-of-vocabulary or below-floor labels reports nothing showable; a gate-2 empty marker
IS reopened once remediation is gate-aware, and a gate-2 *labelled* value is
re-judged rather than ignored.
*Watch:* every one of these must be seen to fail first.

**S2 — the label made visible, attributed (§4A).** Detail view first: what Soundpost
heard, in the reader's language, attributed in the sentence. Then the card — **only
when the capsule has no note**, at caption weight, with the attribution carried in the
accessibility label. Nothing at all on a sealed-not-due capsule; nothing when listening
is off; nothing on the share card or the video.
*Tests:* the policy layer — *which phrases a capsule shows, given its soundprint, its
visibility, its note and consent* — is a pure function and is tested as one, including
the note-precedence rule. Do not claim UI coverage.

**S3 — find others that sounded like this.** `GalleryFilter.Criteria` gains a `sounds`
facet; tapping a phrase in the detail view returns to the gallery with that facet
active and a removable chip in the filter bar.
*Why a facet and not the search box:* free text also matches notes and places, so
"rain" would surface a capsule whose note says rain and whose sound was a train. A
facet says what it means. It costs one field on a value type and reuses the single
walk `GalleryFilter.apply` already does.
*Watch:* **do not derive a facet list by walking the library inside `body`.** The
gallery already re-walks several times per pass and `AudioPlayer` drives updates at
20 Hz while a capsule plays. The chip shown is the one the user just tapped; the
vocabulary needs no enumeration. If you find yourself wanting a full facet list,
that is M18's gallery milestone — and note M16 §7 forbids memoising on
`sealSignature`, which omits content.

**S4 — the honesty sweep.** Read `notificationSettings()` and stop promising a dated
reminder the app has not been permitted to send; stop `seal(until: today)` storing a
past instant (`seal` normalizes unconditionally while `normalizeSealHours` guards
`> now` twice — the inconsistency is what proves it is an oversight); make the
cold-launch deep link actually fire; the mood-filter empty state that currently claims
to be a *search* result; make the "Coming up" strip's **echo** cards tappable (a seal's
is not — its capsule is hidden).
*Watch:* authorization is async and can change while the app is backgrounded — read it
on becoming active, not once at launch.

**Drop order if tight:** S4, then S3. **Never drop:** S0 before S2 — a milestone that
invites more recording while a swipe still destroys a take is the wrong trade.

---

## 6. Privacy / legal delta

**None expected, and checkable.** No new field, no new data category, nothing new
transmitted.

One thing moves in the *right* direction and belongs in the release notes:
`CapsuleBulkExporter` starts honouring listening consent (§4D), so an export taken
while an erase is lagging no longer carries labels.

Verify rather than assert: `PrivacyInfo.xcprivacy` unchanged, and the ASC nutrition
label unchanged — the latter is server-side state nothing in this repo can read, and is
Jason's check (§8), open since M15 §11A#12.

New UI copy — the attribution sentence, the facet chip, the notification-permission
state, and every `accessibilityLabel` — is EN·JA·ZH-Hans in the commit that introduces
it. The localization gate reads source, so an untranslated literal fails CI where it is
added.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A label on a card reads as a fact about someone's memory | §4A: attribution in the copy; never above the user's own words; never leaves the app; detail before card |
| A rejection is lost to CloudKit LWW | Not shipped. §4B, with the repo's own evidence for why |
| A future implementer reaches for the tombstone again | §4B is written as the argument, not the conclusion |
| A ghost section header where every label is unshowable | §4C: showable-labels notion, every render site moved onto it |
| A gate bump strands every gate-2 capsule | S1: remediation becomes gate-aware, both directions tested |
| An orphan sweep deletes a live recording | Not shipped. §4E: observe, do not delete |
| A facet list adds a full-library walk to a 20 Hz path | S3: the chip is the one the user tapped; no enumeration |
| A step quietly needs a CloudKit field | §4F: `promote` prints success and exits before importing on a field-only delta. Stop |
| A test passes without exercising the fix | Every new test run against the pre-fix code and seen to fail (M15 §11P) |
| "No UI test target" makes affordances untestable | Assert on the policy layer; state plainly what is not covered, and verify those by hand in the simulator |

---

## 8. Human-in-the-loop checklist (needs Jason)

1. **Confirm §4B's outcome** — labels ship visible in M17 with attribution and no
   per-label correction; rejection becomes M18's first item behind the promotion. If
   you would rather hold the labels back until correction exists, say so; that is the
   one call that changes the milestone's subject.
2. **One human hour in App Store Connect makes the app sellable.** Capture the IAP
   review screenshot from a StoreKit-testing run, attach it to both products, submit
   them. Until then the paywall is a dead end and no Pro work is worth doing.
3. ~~**The two CloudKit steps**~~ — **done 2026-08-28**, see §13D and §14D. Both
   record types and the never-promoted `CD_soundprintRaw` field are in Production.
   M18 still needs trustworthy tooling, which is now a larger job than §4F described
   (§14C).
4. ~~**Push.**~~ — **done**, and CI has been green on master since 2026-08-26.
5. **Decide whether Soundpost will ever send a "capture today" notification.** Not in
   scope either way (§0B); the answer shapes M18.
6. **The ASC privacy nutrition label** (§6).
7. **The listing** — no mention of listening or search, screenshots from the 1.1.0 app,
   and the echo line ("change or turn it off anytime") that is true on master since M16
   and false in every shipped build. Gated on a release train gated on #3, unless you
   want the 1.6.3-style carve-out you asked to discuss in person.

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| Parse/serialise a soundprint | `Soundprint(stored:)` / `.stored` |
| Localized phrase for a label | `SoundVocabulary.displayName(for:)` |
| Vocabulary membership + per-label floors | `SoundVocabulary.isAllowed`, `.confidenceFloor` |
| Precedence for "user's words beat the machine's guess" | `NotificationCopy.Digest.lead` |
| Consent threaded as a defaulted parameter | `GalleryFilter.apply(_:_:now:listening:)` |
| Content-visibility rule | `Capsule.isContentVisible(now:)` |
| Filter criteria + a collapsible filter bar + chips | `GalleryFilter.Criteria`, `ContentView.filterBar`, `.moodFilterChip` |
| Stopping a recorder and closing the session | `AudioRecorder.cancel()` — it exists, it is just never called |
| A mutating store method with save-failure restore | `CapsuleStore.update` (M16) |
| Why a mutable synced row loses a tombstone | `ListeningConsentStore.set`'s doc comment |

---

## 10. Acceptance criteria

- Every content-visible capsule with showable labels says what Soundpost heard, in the
  reader's language, attributed as a guess.
- The guess never appears above or beside the user's own line, never on a sealed-not-due
  capsule, never with listening off, and never on anything exported or shared.
- Tapping a phrase finds the other capsules that sounded like it.
- A recording in progress survives a swipe, and an orphaned clip is *countable*.
- An export taken with listening off carries no soundprint.
- A gate-2 verdict can be re-judged; nothing is stranded silently.
- Standing bars green at every commit; **no CloudKit schema change anywhere in M17.**

---

## 11. Out of scope / next

- **M18, first item: per-label rejection**, as immutable `SoundRejection` rows — which
  needs the promotion *and* a field-aware `cloudkit-schema.sh` (§4F) before it can be
  verified at all.
- **M18 candidates:** the gallery-performance milestone with a real large-library
  fixture (and the orphan *sweep* inside it, with §4E's two guards); an App Intent for
  capture (no new target, iOS 16+ API, the cheapest answer to a funnel with one entry
  point); the acoustic almanac / "a year ago today"; `sealedAt` so the reveal can say
  how long it was sealed — that one needs the promotion.
- **Not a milestone, but overdue:** the store listing and screenshots (§8.7).

---

## 12. Review record (2026-08-25)

Reviewed by **Gemini 3.1 Pro**, **Gemini 3.7 Flash**, and an **adjudicating third pass
(Claude Opus 4.6)**, each with repo access and each asked to read the code rather than
the plan's description of it.

**Codex was asked and could not answer.** It read the repo for several minutes and then
hit an account usage limit (`ERROR: You've hit your usage limit … try again at Aug 26th
4:15 AM`) without producing a review. That is recorded rather than papered over: this
plan has had three adversarial passes, not the four intended, and the fourth is still
available.

**The reviewers disagreed on the one question the plan turned on, and the disagreement
is why the plan changed.**

- **§4B — overturned.** The draft proposed storing a rejection as a tombstone inside
  `soundprintRaw`. Gemini 3.1 Pro endorsed it, explicitly on the premise that
  "NSPersistentCloudKitContainer performs **field-level merging**", making the
  last-writer-wins risk "vanishingly rare". Gemini 3.7 Flash rejected it on the
  opposite premise and traced three concrete code paths that destroy tombstones. The
  adjudicating pass found the premise settled inside this repo already:
  `ListeningConsentStore.swift:136` documents record-level LWW, written after the same
  mistake cost a redesign. **A reviewer's confident claim about framework behaviour is
  not evidence**, which is the same lesson §11P keeps teaching about gates.
- **All three of Flash's code claims check out**, and were re-verified here:
  `isAllowed("-wind…")` is false, so a gate-aware remediation strips every tombstone;
  `SoundprintEraser` writes `nil` on withdrawal; `isEmpty` is `labels.isEmpty` and
  would render a ghost header. The third is now §4C in its own right, because it is
  reachable today without any tombstone.
- **The orphan sweep — cut.** Both Geminis independently identified the draft's S0
  instruction ("match on capsule rows, not on age alone") as the most dangerous line in
  the plan: the audio file exists from record *start* and the capsule row only from
  *save*, so following it deletes a live take, and a plausible test passes green
  without ever simulating one. §4E now observes rather than deletes.
- **Scope — cut twice.** 3.1 Pro said cut S3 entirely on performance grounds; Flash
  said keep it but sound-only and drop place-browsing and the date-section rewrite.
  Both objections were about deriving a facet list by walking the library in `body`.
  S3 now needs no enumeration at all — the chip is the one the user tapped — which
  answers the objection rather than trading against it.
- **Subject and ordering — upheld by both.** Both said the milestone's subject is
  right and that S1-before-S2 is a hard requirement. Flash argued S4 is a grab-bag and
  that the cold-launch deep link and the seal-today guard are integrity fixes that
  belong earlier; that is noted, and they stay in S4 with S4 no longer the automatic
  first thing dropped.
- **Citations — both reviewers checked §3 and §4 line by line and found every one
  accurate.** That is a better result than M16's draft managed, and it is recorded so
  that a future finding of a wrong citation reads as a regression.

---

## 13. Build record (2026-08-26)

Shipped as planned: **S0 → S1 → S2 → S3 → S4**, each compiling, passing and
committed before the next. Nothing was dropped. Standing bars at close: **513 tests
in 68 suites / 0 warnings on a clean build / i18n EN·JA·ZH-Hans 100% across 335
strings / 93 sound labels / CloudKit seed coverage green.** No new CloudKit field,
no new entity, no promotion — the constraint that lets this run while 1.7.0 is
blocked held all the way through, and no step ever came close to wanting one.

§4B's outcome was implemented as written: **the labels ship visible and attributed,
with no per-label correction.** Nothing found during the build argued against it.

### 13A. Where the plan was wrong, and where I departed from it

**§4C said "give `Soundprint` an explicit showable-labels notion". It also needed a
rename.** `isEmpty` was not merely incomplete, it was *misnamed* — it reads as
"nothing here" and means "no labels in the string". It is now `hasNoLabels`, and the
storage layer still asks it (`SoundprintRemediation` reopens exactly the
analysed-but-empty verdicts). The §11P move applied to a name rather than a gate.

**§S2 asks for "the attribution carried in the accessibility label"; the card carries
it in the visible copy too.** §4A rule 1 forbids "a bare noun sitting where the mood
sits", and the card's slot is the *note's* — a bare "rain" there reads as a caption
the person wrote. So the card renders the whole attributed sentence at caption
weight, and no separate accessibility label is needed because the visible text
already is one. On the detail screen the attribution is a header over chips, which
is not what a literal reading of "in the sentence" suggests: a phrase has to be
tappable on its own to become §S3's facet, and the header sits directly above the
chips so none of them is ever a bare noun in context. Each chip carries the full
sentence as its accessibility label, because VoiceOver can land on one out of the
header's context.

**§S3 says "a `sounds` facet"; it needed `Soundprint.Showable` too.** A chip must
carry both the phrase (for the reader) and the identifier (for the facet), and
deriving one from the other at two call sites is how they drift. One type, one
vocabulary lookup.

**§S4's authorization item became a rule about `.denied` only.** `.notDetermined`
still gets the promise: sealing asks for permission as part of its own flow, so
apologising for a refusal that has not happened is its own small untruth.

**`CapsuleStore.setEcho` was fixed alongside `seal`, which §S4 did not ask for.** It
has the identical defect. The pickers happen to start at tomorrow so it is not
reachable through the UI, but a store method that silently converts a caller's
future instant into a past one is wrong whether or not a screen currently asks it
to.

### 13B. The localization gate could not fail for this milestone's own copy

Found while adding the attribution sentence, and **measured rather than assumed**:
`Soundpost heard %@` was written in source, the project built, and
`Localizable.xcstrings` was untouched. The gate then reported "every source literal
catalogued" while a string that would render in English to every Japanese and
Chinese reader was absent from the catalog entirely.

Check 2 skipped any literal containing `\(`, on the stated grounds that it "lands in
the catalog under a format key instead" — which is what Xcode does when it extracts,
and what this project's build does not. **That is M15 §11P a sixth time, inside the
gate written to close it**, and it was written from a belief about a tool rather than
from what the repository contains.

Closed by SHAPE: `\(anything)` in source and `%@` / `%lld` / … in a catalog key both
collapse to one placeholder, and a source literal must match some catalog key's
shape. Types are deliberately not inferred — the question is "is a string of this
shape catalogued at all", which is the one that was going unasked. Controls: removing
the key turns it red; adding a third interpolation to the existing
`Echoes back %@ · in %lld days` turns it red, which also proves the nested-paren
scanner handles `echoDays(until: echoAt)`.

**A second disguise, found in S4.** The gate finds literals in a localizing *call* or
in a declaration typed `LocalizedStringKey`. A ternary's branches inside `Text(…)`
are in neither, so new copy written that way ships untranslated with the gate green.
Rather than widen the regex to scan call arguments (which would pick up image names
and identifiers), the code was restructured to the `LocalizedStringKey` property
shape the gate already understands — the shape `SealSheet` and `ContentView` already
use. The gate then flagged it correctly. **The residual risk is recorded rather than
closed:** a literal in a third position the gate does not know about would still slip
through.

### 13C. What the tests do and do not cover

There is no UI-test target, and none was added. 73 tests were added across 8 new
suites, every one asserting on a policy or storage layer:

- `SoundprintDisplay` — which phrases a capsule shows, given its soundprint, its
  visibility, its note and consent — is a pure function and is tested as one.
- `GalleryFilter.Criteria.sounds`, `describesASearch`, `Soundprint.showable*`,
  `SoundprintRemediation.supersededPrefixes/rejudge`, `CapsuleStore.humaneInstant`,
  `AudioOrphanAudit.orphans`, `NotificationCoordinator.canPromiseAReminder`.

**Not covered by tests, and verified by hand on the iPhone 17 simulator instead** —
each recorded in its step's commit message:

- `interactiveDismissDisabled` and the discard confirmation (S0): a sheet recording
  at 0:18 does not dismiss on a swipe and runs on to 0:48; Cancel → Discard stops the
  recorder and removes the clip from Application Support; an idle sheet still swipes
  away. The launch orphan audit logged `code 2` for two planted clips and left both
  files in place.
- The card and detail rendering (S2), and the facet round trip (S3), against a
  temporarily-seeded demo library that was **reverted, not committed**.
- The seal sheet's promise copy, the filter empty state, and the echo/seal card
  tapability (S4).

**One item is not verified at all, and is not claimed to be:** the cold-launch deep
link (§S4). `simctl push` delivered the payload and the notification appeared
carrying the right `capsule_id`, but the simulator would not accept a synthetic tap
on a lock-screen or Notification Center entry, so a cold launch was never triggered.
The fix is small and its mechanism is plain — the pending id is now drained from
`.task` as well as `.onChange` — but it wants a confirmation on a real device. It is
in §8 for that reason.

**Every new test was run against a broken implementation and seen to fail.** 39
control mutations in total, listed per step in the commit messages. Three of them
found real problems rather than confirming the tests:

- **J** — deleting `SoundVocabulary.isAllowed` from `Soundprint.isShowable` left
  every test green, because `showablePhrases` launders the answer through
  `displayName(for:)`, which drops unknown labels anyway. But `rejudge` filters on
  `showableLabels`, which does not — so the mutation would have let a **denied** label
  be re-stamped into the current generation where nothing would question it again.
  Moving `rejudge`'s inline check behind `isShowable` had quietly put a real
  guarantee behind an untested condition. Three tests added; the mutation re-run red.
- **AC** — `theFacetNarrowsWithTheOtherCriteria` stayed green with the sound facet
  removed entirely: its mood filter alone already produced the expected single
  result. A third capsule was added and the mutation re-run red.
- **AQ** — `theStripCarriesNoContent` was vacuous on `timeZoneID`, because the
  fixture left it nil and the mutation set it to nil. A reconstruction test proves
  nothing about a field whose expected value is the default.

And one about the harness rather than the code: mutation **AO** was mutually
recursive, the test host crashed, and the runner reported no failures because it
grepped for `✘ Test … failed` lines that a crash never produces. It now reads the
authoritative "Failing tests:" block and warns when no run line appears at all —
the same §11P shape, in my own tooling.

### 13D. Still needs Jason

1. ~~**Push.**~~ Done 2026-08-26/28. CI green on `8a6368e` and again on `83bd776`
   after the review fixes — 529 tests in 72 suites, 0 warnings, i18n 100% across 337
   strings, seed coverage. The gap that had been open since `b025459` is closed, and
   it earned its keep immediately: the first run after the review fixes went **red**
   for a local-only reason (§14E).
2. **The cold-launch deep link on a real device** (§13C).
3. **The ASC privacy nutrition label** (§6). `PrivacyInfo.xcprivacy` is unchanged and
   no new field, category or transmission exists — but it is server-side state
   nothing in this repo can read, and §11A#12 is open precisely because that
   assertion was once made without checking. One thing moved in the *right*
   direction and belongs in the release notes: `CapsuleBulkExporter` now honours
   listening consent (§4D).
4. ~~**The two CloudKit steps**~~ (M15 §11R). **Done 2026-08-28.** A simulator was
   signed into iCloud, the seed created `CD_ListeningConsent` in Development, and the
   Development→Production deploy was performed in the CloudKit Console — it carried
   `CD_soundprintRaw` with it, which had never been in Production (§14D). Production
   now holds every record type the app's schema implies. **1.7.0 is no longer blocked
   on CloudKit**, and the M10 delivery defect's server-side cause is repaired; what
   remains is confirming it end to end by watching `device_tokens` gain rows from a
   signed build.
5. **One human hour in App Store Connect** would make the app sellable (§8.2).
6. **The "capture today" notification decision** (§8.5) — still not in scope either
   way, and it shapes M18.
7. **The demo seed carries no soundprints**, so `-seedSampleData` screenshots show
   none of this milestone. Deliberately not changed here (it is nobody's request),
   but it matters the moment §8.7's screenshots are retaken.

### 13E. What M18 inherits

Unchanged from §11: **per-label rejection as immutable `SoundRejection` rows**, which
needs the promotion *and* a field-aware `cloudkit-schema.sh` (§4F) before it can be
verified at all. The orphan **sweep** now has an observation to build on — and §4E's
two guards plus an exclusion of `AudioRecorder.currentFileName` remain the price of
entry. `Soundprint.Showable` and `SoundprintDisplay` are the seams a rejection would
have to pass through, and both are pure.

---

## 14. External review of the shipped milestone (2026-08-27/28)

M17 was reviewed **after** it shipped, by **Codex** and **Gemini 3.7 Flash**, each
given the same brief and asked to be adversarial. Every code claim was checked against
the repo before being acted on; two did not survive checking and are recorded here
rather than fixed. Four did, and `250f3bd` fixes them.

**Where they agreed, independently:** do not cut a third carve-out branch; the
promotion is the first priority; a field-aware `cloudkit-schema.sh` is M18's price of
entry; and §4B's rejection of the in-string tombstone was correct.

### 14A. The one real disagreement, recorded rather than settled

**Codex dissents from the shipped milestone.** Its position: rejecting the tombstone
was right, but *shipping permanent label visibility without a correction was not* —
"record-level LWW makes the tombstone unsafe, but that does not make uncorrectable
assertions safe". It would have shipped S0/S1/S4, kept the transient capture-sheet
suggestions, and held S2/S3 until immutable `SoundRejection` rows existed, on the
grounds that delayed product value is a reversible harm and a permanently displayed
wrong guess is not.

Gemini took the opposite view: §4A's four gates neutralise the primary harm.

**Not acted on**, and the reasons are worth stating so the next person can reopen it
knowingly. The three-party pre-build review had rule 1 fully in view and concluded
§4A plus the account-wide switch were sufficient; the alternative leaves the
milestone's entire subject invisible behind a blocker of unknown duration; and the
labels were already reaching users — through search, the reveal summary, and the lock
screen — before M17 made them visible, so "hold S2/S3" would not have been the
no-exposure option it sounds like. **Codex's underlying point stands and is the reason
rejection is M18's first item**, not a later one.

### 14B. Four findings, confirmed and fixed

1. **The cold-launch deep link was still lossy — in the code §S4 added.**
   `handleDeepLink` cleared `pendingDeepLinkCapsuleID` whether or not it had found the
   capsule; §S4 then made the drain run at cold launch, which is exactly when CloudKit
   is least likely to have delivered it. The fix moved the loss *closer* to the case it
   was written to repair. Now `CapsuleOpenRoute.pendingLink` returns `.wait`, the link
   survives, and `.onChange(of: capsules.count)` retries. `openCapsule` clears it —
   the user going somewhere themselves is what bounds the wait, so no clock was
   invented.

2. **The consent mirror's default lies on a fresh device, and display believed it.**
   M15 §11Q established exactly this and built *standing* for the retrospective
   drains. M17 added a second way for a label to reach a person and did not extend it.
   `SoundAnalysisPreferences.hasStanding` is now recorded at launch, granted on save,
   and composed into `mayReveal`, which every reveal gate defaults to — display,
   search, facet, export. It defaults to **false**.

3. **The lock screen dressed the guess as the user's own sentence.**
   «"rain" — tap to listen.» `Digest.lead` now carries whose words it is; a heard
   phrase is attributed and unquoted. Predates M17 (M15 §S5) — M17 is what wrote the
   rule it breaks. **An existing test was pinning the defect**, which is why a green
   suite never noticed.

4. **`.notDetermined` promised an echo on a screen that never asks.** The seal sheet
   requests authorization as part of its flow; capture does not, and onboarding — which
   does — has a Skip button. `remindersWouldBeDelivered` is the stricter rule capture
   now uses.

**Not confirmed.** Gemini's `humaneInstant` midnight scenario is unreachable: the seal
picker's `earliest` bound greys out every date through today, checked in the simulator.
Gemini's "the card duplicates the note rule" is a fair coupling observation, but the
view and `SoundprintDisplay` suppress in the same direction, so no wrong result is
reachable today.

### 14C. Still open from the review, for M18

- **`SoundSummaryWriter` produces unattributed prose** from the same phrases, on the
  reveal screen — the most emotionally loaded surface in the app. Codex named it
  alongside the notification copy; only the notification was fixed here. §4A rule 1
  applies to it and it is not yet met.
- **The CloudKit tooling is worse than §4F recorded, and §14D is why.** Not only does
  the promote preview compare type names — `cktool export-schema` itself omits
  unindexed fields, so *no* diff built on it can be trusted to be field-complete, and
  `cktool import-schema` cannot write Production at all. The only trustworthy view of
  a Dev→Prod delta today is the CloudKit Console's own Confirm Deployment dialog.
  Anything M18 builds on `SoundRejection` rows must be verified there, by eye, not by
  this script.
- **The seed's fixed 20-second wait is not enough on a first run after sign-in**
  (§14E), and it reports success without checking that the record type exists.

### 14D. The delta was NOT measured — and what the deployment actually contained

**This section previously claimed the Dev→Prod delta had been verified by field and
was exactly `DeliveryIdentity(userKey)`. That was wrong, and the correction matters
more than the original claim did.**

Both schemas were exported with `cktool export-schema` and diffed. `CD_Capsule` came
back identical, so it was reported as having no field drift. When the CloudKit Console
was finally opened to perform the deploy, it listed something the diff had not:

```
Modify 1 field on CD_Capsule type
  Contains 1 new field:
  CD_soundprintRaw   stringType
```

`grep -c soundprintRaw` over **both** exported files returns **0**. The field is absent
from the Development export too — so `cktool export-schema` does not emit every field.
Every field it *did* emit carries an index annotation (`QUERYABLE`, `SEARCHABLE`,
`SORTABLE`); `soundprintRaw` has none. **The export appears to omit unindexed fields**,
and because the omission is symmetric, a diff of two exports shows nothing wrong.

So the diff was not a field-level check. It was a check over whatever subset cktool
chose to serialise, presented — by me — as a complete one. That is this project's
recurring failure in its purest form, committed while writing the section that
congratulates the project for catching it: *the check iterated an artefact, and could
not fail for what was missing from the artefact.* It also means the tooling is worse
than §4F recorded: `import-schema dev.ckdb` would have silently **dropped**
`CD_soundprintRaw` even if the import endpoint had existed.

**`CD_soundprintRaw` had never been in Production.** That is a live defect of exactly
the same class as `DeliveryIdentity`, in a field shipped since 1.6.0 — and it falsifies
the premise M15 §11Q's whole design rests on:

> "**`soundprintRaw` syncs with the capsule.** The backfill is therefore per-*library*
> work, not per-device — a device with no history running it is redundant as well as
> unsafe, because the labels arrive on their own from whichever device already did the
> work."

In Development that was true. In every shipped build it was not: the labels never
travelled, and a second device re-derived them or went without. The standing design was
correct reasoning over a fact that did not hold. It holds from now on.

**What was actually deployed** (read from the Console, expanded item by item, before
the click):

| | |
|---|---|
| Record types | `CD_Capsule` **+`CD_soundprintRaw`**; create `CD_ListeningConsent`; create `DeliveryIdentity` |
| Indexes | 3 for `CD_Capsule`, 10 for `CD_ListeningConsent`, 3 for `DeliveryIdentity` |
| Security roles | `_world` / `_icloud` / `_creator` each gain the two new types with the default grants every existing type already carries |

All additive; CloudKit cannot do otherwise. Verified afterwards by reading Production
back rather than trusting the click: `status` reports every implied type present, and
the two environments' exports are now identical — *as far as cktool can see*, which is
the caveat this section exists to record.

### 14E. Two incidents during the review, neither of them in the product

- **iCloud conflict copies broke the build mid-session.** `~/Documents` is iCloud-synced
  and Soundpost's `.xcodeproj` uses file-system-synchronized groups, so four
  `X 2.swift` files appearing at once (stale pre-§11P copies, `mtime Aug 18`) meant
  `invalid redeclaration of 'ListeningConsentStore'`. They were untracked but **not**
  gitignored, so a `git add -A` flow would have committed four files that silently
  revert the consent redesign. Moved aside, not deleted; the pushed commits were never
  affected.
- **A green local suite that CI reddened**, and the reason is worth carrying: the test
  host shares `UserDefaults.standard` with the app, so having driven Soundpost in the
  simulator had written `sound.hasStanding` and made the new default look harmless.
  Three tests failed on CI; **five more would have passed vacuously**, because they
  assert a search finds *nothing* and a closed gate satisfies that without exercising
  anything. When a gate's default moves, the assert-emptiness tests are where the
  damage hides. Fixed in `83bd776`, verified with the app uninstalled.

### 14F. One hazard sitting in front of §8.2

`~/.zshrc:68` exports `ASC_APP_ID="6761163709"` — **CLI Pulse Bar's** id, not
Soundpost's `6778389097` — and `scripts/asc.py:24` honours the environment over its
default, using it for reads *and* creates. Any Soundpost App Store Connect work run
from the interactive shell would target the wrong app. Found by Codex, which had it in
its own environment. Unset it for the session, or the ASC hour in §8.2 starts by
editing someone else's listing.

---

## 15. 1.7.0 shipped to review (2026-08-28)

**`WAITING_FOR_REVIEW`, build 16, submission `a977308d`.** The release that had been
code-complete and unshippable since 2026-08-23 is out. What unblocked it was not code:
a simulator signed into iCloud, a seed run twice, and a deploy performed in the
CloudKit Console because no CLI can do it (§14D).

**What actually shipped in it.** 1.7.0 was named for account-wide listening consent.
By the time it could be uploaded it also carried M16 and M17 — 32 commits — so the
release notes were rewritten to say so, in three languages, led by the thing the
release is really for: what Soundpost heard is now on the capsule, attributed, never
as a claim about the reader's memory. Codex's review had warned against shipping
"blindly from current master"; this accepts the enlarged scope deliberately rather
than by omission.

### 15A. Three false successes found on the way out

Each reported "fine" and was not. They are listed together because the shape is one
this project has now hit **nine** times, and three of them were in the release
tooling itself — the part nobody exercises until the day it matters.

1. **The schema seed.** Printed `SCHEMA-SEED cleaned up` while creating no record
   type. Its fixed 20-second wait expired mid-`CKModifyRecordZonesOperation`, which
   took 30.5 s on a first run after sign-in; the delete beat the export, the two
   coalesced, and the follow-up export was `madeChanges: 0`. Its own comment guards
   the sleep against *cancellation* and not against being too short, and it never
   checks that the type exists. Running it twice worked.
2. **`cloudkit-schema.sh promote`.** Could not have worked at all — `cktool
   import-schema` writes Development only and cktool has no deploy subcommand. Written,
   never exercised, invisible until needed.
3. **`upload-dsyms.sh`.** Swallowed sentry-cli's exit status, so an expired-looking
   token (`Invalid token`, 401) was reported as a completed step. This is precisely
   the incident the script exists to prevent — 1.6.0 build 12 shipped unsymbolicated
   for a different reason with the same silence. Now `|| return 1`; verified by
   re-running the same failure and watching the exit code go 0 → 1.

The 401 turned out not to be an expired token: the value in `~/.zshrc` was the token
**wrapped in angle brackets** (73 chars, `<` … `>`). Two characters. But it would have
shipped unsymbolicated again, silently, if the script had not been fixed first.

### 15B. What is now true that was not

- CloudKit **Production** holds `CD_Capsule` (with `CD_soundprintRaw`),
  `CD_ListeningConsent`, `DeliveryIdentity` and `Users`.
- `CD_soundprintRaw` reaching Production means sound labels can sync between a
  person's devices **for the first time**, and M15 §11Q's premise finally holds.
- The M10 delivery defect's server-side cause is repaired. **Unconfirmed end to end:**
  `device_tokens` and `notification_jobs` gaining rows from a signed build is the only
  proof, and their emptiness is the only reason anyone noticed.
- 1.7.0's dSYMs are in Sentry, so its Release crashes will symbolicate.

### 15C. Still open

1. **Release 1.7.0 when Apple approves it** — `scripts/asc.py release`, which acts only
   on `PENDING_DEVELOPER_RELEASE`. Deliberately left to a human.
2. **Confirm M10 end to end** (above).
3. **The cold-launch deep link on a real device** — M17's one unverified item, now
   twice-modified and more worth checking than before.
4. **The ASC hour for the two `MISSING_METADATA` IAPs**, with `unset ASC_APP_ID` first:
   `~/.zshrc` points it at CLI Pulse Bar (§14F).
5. **The ASC privacy nutrition label** (§6) — still server-side state nobody has read.
   M17 added no field, category or transmission, and moved the export *toward* less
   data; the check remains outstanding rather than assumed.
6. **The store listing** — no mention of listening or search, screenshots from 1.1.0.
   More overdue than ever now that the labels are visible.
7. **`* 2.swift` / iCloud Drive** — the working tree still lives where conflict copies
   can appear and break the build (§14E).
