# M16 — "Your words"

> Let people fix their own memory, and hear it without leaving the gallery.
> Drafted 2026-08-23; **rewritten the same day** after Codex, Gemini 3.1 Pro and
> Gemini 3.7 Flash all rejected the first draft's subject. See §12.

---

## 0. Goal & success statement

Soundpost cannot edit a capsule. `CapsuleStore` has `create`, `delete`, the lifecycle
transitions and `setEcho` — and no way to change a **note, mood, or place** once saved.
A typo in the one line you wrote about your grandmother's kitchen is permanent, and the
only way out is deleting the recording.

Two things make that worse than an inconvenience:

- **A machine guess can become the user's own frozen words.** Tapping a sound
  suggestion in the capture sheet *appends the phrase to the note*
  (`CaptureView.swift:268` → `acceptSuggestion`). If the classifier was wrong, that
  wrong noun is now permanent text in the user's diary line — and no amount of
  correcting `soundprintRaw` later removes it. Rule 1 is being broken today, through a
  door only editing can close.
- **A sealed capsule freezes the mistake for as long as the seal.** A typo in a
  five-year capsule is locked in for five years.

**Success:** a person can fix what they wrote, hear a capsule from the gallery without
a screen transition, and never see a lock-screen reminder quoting a sentence they have
since changed.

**Not success:** new surfaces, new Pro levers, new machine cleverness.

### 0A. Why this and not "make the sound visible"

The first draft of this milestone was the sound work: show the 93 labels on the card,
let people reject a wrong one, add filter chips. **All three reviewers independently
said editing should come first**, and the argument that settled it is the one above —
the machine's guess is already leaking into the user's own permanent words, and the
sound-correction design does nothing about that.

The rest of the case, in the order it convinced me:

1. **It is not blocked.** `note`, `mood`, `place` and `echoAt` all already exist on
   `Capsule` (`Capsule.swift:60–76`). **M16 needs no new field, therefore no CloudKit
   schema promotion.** The sound plan's first step was a promotion — which would have
   made this milestone inherit exactly the human blocker 1.7.0 is already stuck behind.
   This one can start now.
2. **The sound-correction contract is not settled.** Codex showed the proposed
   two-place scheme repeats the mistake this project *just* fixed in consent: two
   offline devices rejecting different labels both mutate the same `CD_Capsule`, and
   CloudKit's own last-writer-wins can restore a label while dropping its tombstone.
   Getting that right likely needs immutable rejection rows — a design worth doing
   properly in M17 rather than locking an unproven one into Production forever.
3. **A wrong label is currently almost invisible; a wrong note is not.** Labels appear
   only in the capture sheet and inside an AI sentence that refuses when ungrounded.
   Deferring the sound work does not *increase* rule-1 exposure — it just doesn't
   reduce it. Deferring editing leaves a defect people meet every time they mistype.

The sound work moves to M17 intact (§11).

---

## 1. Non-negotiables (carried from PROJECT.md / M9–M15)

1. **Never tell someone their memory was something it wasn't.** Editing is how the
   person gets the last word over both their own typo and the machine's suggestion.
2. **A capsule is a keepsake, not surveillance.**
3. **Shipped copy must be literally true** — including copy already scheduled onto a
   lock screen. §4C is the whole of that problem.
4. **Calm.** No edit badges, no "last edited" chrome, no revision history UI.
5. **Free stays free.** Fixing your own words is never a paid feature.
6. **Offline-first, on-device.** No new backend, **no new CloudKit field, no schema
   promotion.** If a step seems to need one, stop — it belongs in M17.
7. **Standing bars, every step:** warning-free on Xcode 26, all tests green, i18n
   EN·JA·ZH-Hans 100%, zero new dependencies, CI green.

---

## 2. Scope

**In:** S0 inline playback · S1 content-dependent notification invalidation ·
S2 editing note / mood / place / echo.

**Out, deliberately:**

- **The whole sound-visibility milestone (→ M17):** showing labels on the card,
  "not this sound", find-similar, filter chips. Its storage contract is unsettled
  (§0A.2) and its first step is an irreversible schema promotion.
- **Editing `createdAt`.** A capsule is *when it happened*. Making the date editable
  turns a keepsake into a document, and it silently re-orders the gallery, re-groups
  the date sections, and invalidates seal/echo arithmetic.
- **Editing the audio.** No trimming, no re-recording into an existing capsule.
- **Revision history / undo stack.** One level of in-sheet cancel, no more.
- **Editing a sealed-not-due capsule's content** — see §4B.

---

## 3. Current state (grounded — cite before you change)

Verified against `master` @ `336216c`, 1.7.0 / build 16, 413 tests green.

| Fact | Where |
|---|---|
| No update path for note / mood / place | `Services/CapsuleStore.swift` — create, delete, transitions, `setEcho` only |
| `setEcho` exists and is the shape to copy | `CapsuleStore.swift:104` |
| Detail view renders note/place read-only | `CapsuleDetailView.swift:140–149` |
| Detail view has a toolbar menu to hang "Edit" on | `CapsuleDetailView.swift:54` |
| A sound suggestion is appended to the **note** | `CaptureView.swift:268` `acceptSuggestion` |
| Personalized notification copy leads with the note | `NotificationCopy.Digest.lead` |
| Notification identity ignores content | `NotificationScheduler.identifier(for:contentVersion:)` — capsule id, kind, fire date, and a global `g1`/`p1`/`p1n` token |
| `contentVersion` moves only on the two global toggles | `NotificationPreferences.swift:43` |
| Reconcile skips an identifier it already scheduled | `NotificationScheduler.swift:73` |
| The card is wrapped in a whole-card `Button` | `ContentView.swift:128`, `.buttonStyle(.plain)` |
| The card's play glyph is decoration | `CapsuleCard.swift:90` — inside a `Label` |
| Detail view owns its **own** `AudioPlayer` | `CapsuleDetailView.swift:14` |
| The player ticks at 20 Hz | `AudioPlayer.swift:96` — `withTimeInterval: 0.05` |
| `sealSignature` omits content | `ContentView.swift:317` — id, state, sealUntil, echoAt only |
| There is no UI-test target | `Soundpost.xcodeproj/project.pbxproj` — app + unit tests only |

---

## 4. Architecture / design decisions

### 4A. One playback owner for the whole app

A play control on the card means many potential players in a `LazyVStack`, and the
detail view already constructs its own (`CapsuleDetailView.swift:14`). Reviewers found
three ways that overlaps: gallery + detail, gallery + resurface reveal, gallery +
capture preview.

So playback gets **one owner**, held above the gallery, with a `playingCapsuleID`.
Opening a capsule, presenting the reveal, presenting capture, or the scene going
inactive all stop it. `playingCapsuleID` must clear on natural completion **and** on
failure, or the UI keeps showing a pause button for audio that already stopped.

### 4B. What may be edited, and when

Editable: **note, mood, place, echo.** Not `createdAt`, not the audio (§2).

**Content visibility is the gate**, reusing the rule the rest of the app already
follows (`Capsule.isContentVisible(now:)`). A sealed-not-due capsule's note is hidden
from its owner by design; an edit sheet that displayed it in a text field would be a
back door around the seal. So: no content editing while sealed-not-due. Changing the
**seal date** or unsealing already exist and stay the way out.

### 4C. Editing breaks a promise the notification system cannot currently keep

This is the milestone's real engineering, and it was invisible until three reviewers
pointed at the same line.

A personalized reminder's body is **baked at schedule time** and leads with the user's
note. Edit the note and the pending lock-screen body still quotes the old sentence — up
to years later, for a seal. `NotificationPreferences.contentVersion` exists precisely to
invalidate stale bodies, and **it cannot help here**: it is a single global token
(`g1`/`p1`/`p1n`) that moves only when the personalized or listening toggle flips. Edit
one capsule and the identifier is unchanged, so `reconcile` hits
`guard !existingSet.contains(id) else { continue }` (`NotificationScheduler.swift:73`)
and skips rebuilding that request. The old words stay on the lock screen.

**Fix:** fold a **per-capsule content fingerprint** into the request identifier — a
short stable hash of exactly the fields the body can render (note, place name, mood,
and the soundprint, since `Digest.lead` can fall back to it). Content changes →
identifier changes → the stale request is removed and re-added with the new body. This
is the same reasoning that put `contentVersion` there in the first place, applied at
the granularity the problem actually has.

It is S1, before editing, because editing without it ships a rule-3 violation. M17's
sound correction needs the identical mechanism.

### 4D. A failed save must leave nothing half-applied

`rollback()` does not restore already-materialised objects — this project has learned
that twice (the backfill's first consent fix, and `ListeningConsentStore.set`). The
edit commit captures the previous values, and restores them by hand if `save()` throws,
then surfaces the failure. A silent failure here means the user believes they fixed a
typo that is still there.

### 4E. Nested controls inside a whole-card Button

`ContentView.swift:128` wraps the entire card in a `Button`. Putting a play control
inside it gives SwiftUI two overlapping tap targets, and `CapsuleCard` also merges its
accessibility children. Restructure so the card's *surface* handles navigation and the
play control is a sibling with its own hit region and its own accessibility element —
do not simply nest a second `Button`.

---

## 5. Work breakdown (sequenced; each step compiles + passes tests + commits)

**S0 — inline playback.** One app-level playback owner (§4A), a real play/pause control
on the card replacing the decorative glyph, stop-on-navigate / reveal / capture /
inactive. No control at all on a sealed-not-due capsule. Restructure the card's tap
targets (§4E).
*Tests:* only one player is ever active; opening detail stops the gallery player;
`playingCapsuleID` clears on completion and on failure; a sealed-not-due capsule
exposes no play affordance.
*Watch:* the 20 Hz tick (`AudioPlayer.swift:96`) drives view updates while playing —
do not add any per-body work over the whole library, and note that `displayed`,
`upcoming`, `storageString` and `sealSignature` already each re-walk it.

**S1 — content-dependent notification invalidation.** Per-capsule content fingerprint
in the request identifier (§4C). No user-visible change; this is the enabling step.
*Tests:* schedule a personalized reminder for a capsule with a note, change **only**
the note, re-sync, and assert the pending request's body changed. That test must be
written so it **fails** before the fix — a test that only checks "a request exists"
passes today and proves nothing.

**S2 — editing.** An edit sheet from the detail view's existing toolbar menu: note,
mood, place, echo. `CapsuleStore.update(...)` in the shape of `setEcho`. Content-visible
capsules only (§4B). Save-failure restore (§4D). Re-sync notifications on save, which
now actually rebuilds the body because of S1.
*Tests:* each field round-trips; a sealed-not-due capsule cannot be content-edited; a
throwing save leaves the capsule exactly as it was **and** surfaces an error;
`createdAt` is unchanged by every path; editing a note updates the pending reminder.

**Drop order if tight:** S0. **Never drop:** S1 before S2 — editing without invalidation
ships a false lock-screen quote.

---

## 6. Privacy / legal delta

**None expected, and this time the claim is checkable:** no new field, no new data
category, nothing new transmitted. Editing changes values in fields already declared,
already synced, and already exported by `CapsuleBulkExporter`.

Verify rather than assert: `PrivacyInfo.xcprivacy` unchanged, and the ASC nutrition
label unchanged (§11A#12 is still open precisely because that assertion was once made
without checking).

New UI copy — the edit sheet, its fields, its errors, and every `accessibilityLabel` —
is EN·JA·ZH-Hans in the commit that introduces it. The localization gate now reads
source, including `LocalizedStringKey` bodies and accessibility modifiers, so an
untranslated string fails CI where it is added.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A pending reminder quotes an edited-away sentence | S1, before S2, with a test that fails without it |
| A failed save silently loses the edit | §4D: capture and restore by hand, surface the error |
| Editing reveals sealed content | §4B: content-visibility gate, regression test |
| Overlapping audio | §4A: one owner, stop on every transition |
| Gallery re-render storm at 20 Hz while playing | No new per-body library walks; memoise on a signature that includes what it depends on — **not** `sealSignature`, which omits content (`ContentView.swift:317`) |
| Nested tap targets swallow the play control | §4E |
| A test passes without exercising the fix | Every new test is run against the pre-fix code and must be seen to fail (the §11P discipline) |
| "No UI test target exists" makes control affordances untestable | Assert on the view model / policy layer, not the view; do not claim UI coverage the project cannot run |

---

## 8. Human-in-the-loop checklist (needs Jason)

1. **Nothing blocks M16.** This is the point — no simulator sign-in, no promotion.
2. The two 1.7.0 blockers remain independently outstanding (§11R).
3. Confirm the §2 exclusions: `createdAt` immutable, no audio editing, no revision
   history, no content editing while sealed-not-due.
4. Confirm M17 is the sound milestone.

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| A mutating store method to copy | `CapsuleStore.setEcho` |
| Echo date picking + normalisation | `SealSheet`, `SealClock.normalize` |
| Mood picker | the capture sheet's mood chips |
| Place capture | `LocationProvider`, `Place` |
| Playback | `Audio/AudioPlayer.swift` |
| Content-visibility rule | `Capsule.isContentVisible(now:)` |
| Notification reconcile + identifiers | `NotificationScheduler` |
| Save-failure restore pattern | `ListeningConsentStore.set` |

---

## 10. Acceptance criteria

- Note, mood, place and echo can each be changed and persist; `createdAt` never moves.
- A sealed-not-due capsule cannot have its content edited or played.
- Editing a note changes the pending personalized reminder's body.
- A capsule plays from the gallery card; exactly one plays at a time; the control
  clears on completion and on failure.
- A throwing save leaves the capsule untouched and tells the user.
- Standing bars green at every commit; no CloudKit schema change anywhere in M16.

---

## 11. Out of scope / next — M17, "What your life sounds like"

The first M16 draft, preserved because the analysis was sound even though the ordering
was not. Show the sound on the card and in detail, let people reject a wrong one, and
find similar capsules. Before it starts, three things must be settled:

1. **The rejection storage contract.** A mutable string edited by two offline devices
   loses tombstones to CloudKit's last-writer-wins — the same failure consent had.
   Immutable rejection rows are the likely answer; that is a schema change and a
   promotion.
2. **Field-aware CloudKit tooling.** `cloudkit-schema.sh` compares record **type
   names** only, so for a field-only change `status` reports success, `promote`
   prints *"Nothing to do — Production already matches"* and **exits without
   importing**, the post-import readback checks types, and `CloudKitSchemaSeed` skips
   `Capsule` entirely. Four places, all of which must learn about fields before any
   field-based feature can be verified at all.
3. **Correction must not grandfather a stale label.** Removing one label from a gate-1
   soundprint and reserialising the survivors stamps them at the *current* gate,
   permanently shielding values the newer floors would have rejected. Survivors must be
   revalidated before restamping.

Also deferred: the acoustic almanac / "a year ago today"; gallery performance as a
milestone of its own; stereo capture and playback conditioning.

---

## 12. Review record (2026-08-23)

Reviewed by **Codex**, **Gemini 3.1 Pro** and **Gemini 3.7 Flash**, each given the same
brief and repo access, each reading the code rather than the plan's description of it.

**They rejected the milestone's subject, unanimously**, and the plan above is the
rewrite. The deciding fact — that accepting a sound suggestion writes the machine's
phrase into the user's permanent note — came from Codex and is verified at
`CaptureView.swift:268`.

Findings folded in from all three:

- **§3A of the first draft was factually wrong**, and all three caught it. It claimed
  bumping `Soundprint.schemaVersion` would make older builds re-analyse over a
  correction. It would not: `SoundprintBackfill` selects with a SQL predicate on the
  *column* (`$0.soundprintRaw == nil`), not on a parse, so a `2/…` value is simply
  never selected. The real consequence is quieter — older builds would show *no* labels
  at all on that capsule — and the conclusion happened to survive the wrong reasoning.
- The CloudKit tooling is field-blind in **four** places, not the one the draft found
  (Gemini 3.7 Flash, confirmed by Codex; §11).
- The notification-invalidation trap (all three, independently) — now §4C, and the
  reason this milestone has an S1 at all.
- The proposed rejection storage repeats the consent LWW mistake (Codex; §11.1).
- Memoising chips on `sealSignature` would freeze them, since it omits content
  (Gemini 3.1 Pro) — now a general warning in §7.
- Nested controls inside the whole-card `Button`; the detail view's second
  `AudioPlayer`; the 20 Hz tick (Gemini 3.7 Flash, Codex) — now §4A, §4E, §7.
- Draft errors corrected: `CapsuleStore` *does* have an update path (`setEcho`); the
  93-label vocabulary stores at most 3 per capsule; "nothing new is transmitted" was
  false for a synced rejection field.

Acted on immediately rather than deferred: the localization gate did not look at
`.accessibilityLabel`, so VoiceOver copy could ship untranslated. Extended and
control-tested the same day; all 12 existing labels were already catalogued, so nothing
was live.
