# M18 — "No, it wasn't"

> M17 made the machine's guess visible. M18 lets the person say it is wrong, and
> fixes the last surface that still presents a guess as a fact. Drafted 2026-08-29,
> the day 1.7.0 went live.

---

## 0. Goal & success statement

Soundpost now tells you what it heard, on the card and on the capsule, attributed in
the copy. It has no way for you to say **no**. M17 deferred that deliberately (§4B of
that plan) because the only storage available at the time would have lost the
rejection; the storage it needed is now deployed.

**Success:** a wrong label can be dismissed, the dismissal survives a sync, a gate
bump, a re-analysis and a consent cycle, and it is visible nowhere the label was —
card, detail, search, facet, export, lock screen. And the reveal screen stops
describing a guess as a fact.

**Not success:** a new mutable field on `Capsule`; a rejection that a background pass
can quietly undo; a "was this right?" prompt that turns a keepsake into a labelling
task.

### 0A. Why this, and why now

1. **It is the one unmet half of rule 1.** *Never tell someone their memory was
   something it wasn't.* M17 met it by attribution, visibility limits and an
   account-wide off switch — and Codex's post-ship review said plainly that this is
   not enough: "record-level LWW makes the tombstone unsafe, but that does not make
   uncorrectable assertions safe" (M17 §14A). That objection was recorded rather than
   settled. This settles it.
2. **The blocker is gone.** M17 §14D: the CloudKit Development→Production deploy is
   done. A **new record type** is exactly what the existing gate *can* verify — it
   derives expectations from `Schema([...])` and compares type names
   (`cloudkit-schema.sh:48`). The field-blindness that ate `CD_soundprintRaw` bites
   when adding a field to an *existing* type, which this milestone does not do.
3. **The shape is already proven in this repo.** `ListeningConsent` is append-only
   immutable rows with latest-answer-wins (`ListeningConsent.swift:37`,
   `ListeningConsentStore.winner:21`), built after the same mistake cost a redesign.
   M18 copies it rather than inventing.

### 0B. What this milestone deliberately does NOT do

- **No new field on `Capsule`.** §4G. The tooling cannot verify one, and M17 §14D is
  the evidence: `CD_soundprintRaw` sat missing from Production since 1.6.0 and every
  check said fine. `sealedAt` and anything else field-shaped waits for tooling.
- **No re-analysis triggered by a rejection.** Rejecting "rain" says *do not show me
  this*, not *go and look again*.
- **No prompting.** Nothing asks whether a label was right. The affordance is there
  when you go looking for it and silent otherwise (rule 4, calm).
- **No Pro lever.** Both IAPs are still `MISSING_METADATA` (§8).
- **No gallery-performance work.** Still its own milestone, still needs a real
  large-library fixture, which does not exist (`grep` over `SoundpostTests`: nothing
  seeds more than a handful).

---

## 1. Non-negotiables (carried from PROJECT.md / M9–M17)

1. **Never tell someone their memory was something it wasn't.** M18 is this rule.
2. A capsule is a keepsake, not surveillance.
3. Shipped copy must be literally true.
4. Calm. No counters, no streaks, no engagement loops, no prompts.
5. Free stays free.
6. **Offline-first. A new entity is allowed here and nothing else is** — no new field
   on an existing type, and the promotion is verified in the CloudKit Console by eye
   (M17 §14C), not by a script that cannot see fields.
7. Standing bars, every step: warning-free on Xcode 26, all tests green, i18n
   EN·JA·ZH-Hans 100%, zero new dependencies, CI green.

---

## 2. Scope

**In:** S0 the reveal stops asserting a guess · S1 the guard that must exist first ·
S2 the rejection row · S3 saying no · S4 everything that must honour it.

**Out:** any new `Capsule` field; **the orphan sweep** (§4E — cut after all three
reviewers found a different hole in it); the acoustic almanac; `sealedAt`; App
Intents; gallery performance; the store listing (§8); re-recording, trimming, editing
`createdAt` (unchanged since M16 §2).

---

## 3. Current state (grounded — cite before you change)

Verified against `master` @ `4b21faf`, 1.7.0 **live** (`READY_FOR_SALE`), 529 tests in
72 suites, 0 warnings, i18n 100% across 337 strings.

| Fact | Where |
|---|---|
| One function decides which labels are showable | `Soundprint.showable()` — `Soundprint.swift:200` |
| **But seven call sites reach it by different routes**, not one seam | `SoundprintDisplay` (card, detail); `GalleryFilter:122` facet **and** `:141` search; `CapsuleBulkExporter:169`; `NotificationCopy:62`; `CaptureViewModel:52`; **`ResurfaceView:161`** |
| Display policy is one pure function of capsule + surface + clock + consent | `Services/SoundprintDisplay.swift` |
| A reveal facet matches on the **identifier**, never the phrase | `GalleryFilter.soundFacetMatches` |
| Immutable append-only rows, latest-wins, with a clock clamp | `ListeningConsent.swift:37`, `ListeningConsentStore.swift:21`, `:32` |
| Why a mutable synced row loses an answer | `ListeningConsentStore.set`'s doc comment |
| Reveal prose is generated from labels **as facts**, unattributed | `SoundSummaryWriter.swift:339` instructions, `:354` prompt |
| The schema gate sees record **types**, derived from `Schema([...])` | `scripts/cloudkit-schema.sh:48` |
| ~~`cktool export-schema` omits unindexed fields~~ — **false, corrected by M19 §4C**: the export matches the Console field for field. The real gap is that neither environment holds a field the app declares but has never written | M17 §14D, M19 §4C |
| `promote` cannot deploy; the Console is the only path | M17 §14D, `cloudkit-schema.sh` |
| Orphaned audio is counted, never swept, and why | `Services/AudioOrphanAudit.swift` |
| CloudKit Production holds CD_Capsule (+CD_soundprintRaw), CD_ListeningConsent, DeliveryIdentity, Users | `cloudkit-schema.sh status` |

---

## 4. Architecture / design decisions

### 4A. A rejection is a row — but NOT a wholesale copy of `ListeningConsent`

The row *shape* is right, for the reason `ListeningConsentStore.swift:136` documents:
once a row has synced, two devices editing it are editing the same CKRecord and
`NSPersistentCloudKitContainer` resolves that with **record-level** last-writer-wins
before either version reaches our code.

```swift
@Model final class SoundRejection {
    var id: UUID = UUID()
    var capsuleID: UUID = UUID()
    var identifier: String = ""      // the classifier identifier, never the phrase
    var rejected: Bool = true        // false = undo, so a mis-tap is recoverable
    var changedAt: Date = Date.distantPast
}
```

**The resolution logic is NOT a copy.** All three reviewers landed on this from
different angles and they are right: `ListeningConsent` answers *one global question*,
so `winner()` takes the max over the whole table. Rejection has **many independent
keys**. Every part of the algorithm must therefore be scoped to `(capsuleID,
identifier)`:

- `winner` is a winner *per key*, not a single row for the table;
- future-date settlement (`effectiveDate`, `settleFutureDatedAnswers`) applies per key;
- compaction — a newer answer supersedes strictly-older rows — applies per key, which
  is what keeps rapid toggling from leaving dozens of permanent rows;
- **the tie-break prefers `rejected == true`.** When two answers cannot be ordered,
  take the one that says stop. That is the rule §1.2 already has, and here "stop" means
  "do not show it".

**One inherited bug not to inherit.** `ListeningConsentStore.set` deletes superseded
rows and, on a save failure, removes only the *new* row — correctness then depends on
the caller rolling back (`ListeningConsentStore.swift:155`, `:168`). Found by Codex
while reading the code M18 proposes to copy. The new store restores **all** of it, the
way `SoundprintRemediation.rejudgeBatch` and `AudioMigrator.flush` already do.

**Keyed by identifier, not phrase.** A phrase is language-dependent and would strand a
rejection made in Japanese when the phone switches to English. Same argument as M17
§S3's facet.

*Known limit, recorded rather than solved:* if the classifier's taxonomy ever changes
an identifier (`rain` → `precipitation`), a rejection keyed to the old one is bypassed
and the sound returns under a new name (Gemini 3.7 Flash). The vocabulary is curated
here (`SoundVocabulary.displayNames`), so this is a change we would be making, not one
happening to us — the migration belongs in whatever milestone makes it.

### 4B. There is no "one seam" — so make the compiler produce the list

The plan's first draft claimed every consumer reads `Soundprint.showable*` and would
therefore inherit rejection for free. **That is false, and Codex proved it by reading
the code:** `SoundprintDisplay` is used by the card and the detail screen, while
`GalleryFilter` (twice — `soundMatches` at `:141` *and* `soundFacetMatches` at `:122`
are separate call paths), `CapsuleBulkExporter`, `NotificationCopy.Digest.lead`,
`CaptureViewModel.suggestedPhrases` and **`ResurfaceView.swift:161`** all call
`showable*` directly. The first draft's §S3 listed five of those and missed the
reveal — which is exactly the surface §4D is about, so a rejected label would have
been fed to the prose generator by the very milestone that set out to stop it.

So the mechanism is not documentation. **Remove the zero-argument display APIs.**
`showable`, `showablePhrases` and `showableIdentifiers` each take a rejection index
with **no default**, and the build fails until every call site has been visited. A
call site that genuinely has none spells it `rejecting: .none` and says why — capture
is the honest case, since a capsule that does not exist yet cannot have rejections.

This is the §11P remedy in its strongest available form: not a check that iterates the
consumers, but a compiler that cannot finish while one is missing.

**One `@Query` is not enough either.** The gallery can thread a UI query, but
`RemoteChangeReconciler` builds notification copy outside any view
(`RemoteChangeReconciler.swift:48`) and `CapsuleBulkExporter` is a `@ModelActor` with
its own context (`CapsuleBulkExporter.swift:104`). Each of those does **one scoped
fetch per operation** — not a UI query, and not a fetch per capsule.

**The index is a value type, built once.** `RejectionIndex` wraps
`[CapsuleID: Set<String>]` with the per-key winners already resolved, so a card asks it
a `Set` question and never re-runs resolution. Rebuilding winners from every row during
a 20 Hz gallery pass would simply move the performance bug (Gemini 3.1 Pro, Codex).

### 4C. What must honour a rejection, and the one thing that must not

Honour it: the card, the detail chips, search, the sound facet, the bulk export, and
`NotificationCopy.Digest.lead`. All six read the seam, so all six inherit it — and each
gets a test that fails without it, because "it inherits" is a claim, not a fact.

**Must NOT honour it: `SoundprintBackfill` and `SoundprintRemediation`.** They decide
what the *classifier* heard; a rejection is what the *person* said about it. Filtering
the backfill by rejections would mean a reopened capsule silently loses the row's
subject, and re-analysis would then have nothing to be rejected against — and an undo
could never restore a label that storage no longer held. All three reviewers agreed
this separation is right; it is the same one that keeps `hasNoLabels` (storage) and
`showablePhrases` (display) apart.

**Two things a rejection must actively push, not merely filter** (Codex):

- **Notifications already scheduled.** A lock-screen body has its text baked in at
  schedule time. M16 built `contentVersion` and the per-request content fingerprint
  for exactly this; a rejection must trigger `notifications.sync(...)` the way an edit
  does (`CapsuleDetailView.resyncAfterEdit`), or the rejected phrase keeps firing.
- **A reveal generation in flight.** `SoundSummaryWriter` is called from `.task` when
  the screen appears; a rejection made while it is running must cancel or discard the
  result, or stale prose lands after the label was dismissed.

### 4D. The last surface that presents a guess as a fact — and why a validator cannot fix it

`SoundSummaryWriter` hands the model `Sounds heard: rain, wind` under instruction 1,
"Use only the given facts" (`SoundSummaryWriter.swift:343`). It will write *"A rainy
morning at home."* — a classifier guess, stated as fact, in generated prose, on the
reveal screen, which is the most emotionally loaded moment the app has. M17 wrote the
rule this breaks and did not fix it (M17 §14C).

**The first draft proposed enforcing honesty with the output validator. All three
reviewers rejected that, independently, and they are right.** The existing validator
proves the sentence *mentions* a supplied fact and is in the right script
(`SoundSummaryWriter.swift:196`, `:298`); distinguishing "a rainy day" from "sounds of
rain" is not a lexical property, and no regex does it across EN, JA and ZH-Hans at
once. A validator built to try would either drop good sentences or pass bad ones, and
rule 1 would be resting on a heuristic.

**So the guess never reaches the generator.** `Facts.soundPhrases` is removed from the
prompt entirely. The summary is built from what the person themselves supplied — their
note, their place, how long ago — and the reveal shows **`SoundprintDisplay.sentence`**
beneath it, the same deterministic attributed line the card already uses: *"Soundpost
heard rain and leaves in the wind."*

The reveal thereby gains the attribution it never had, the prose can no longer assert
a guess because it is never told one, and nothing rests on the model's cooperation.
Instruction 5 ("if the facts are too thin, repeat the given sounds plainly") goes with
it — a capsule with no note and no place now simply gets no sentence, and the attributed
line carries the screen. That is a smaller feature, honestly.

### 4E. The orphan sweep is CUT — three reviewers, three different holes

M17 refused to ship it. This plan proposed it with two guards. **All three reviewers
attacked it, each finding a different hole, and none of the three is answered by the
guards as written:**

- **The launch audit has no recorder.** `AudioOrphanAudit.report` is called from
  `SoundpostApp.swift:161` and `currentFileName` belongs to an `AudioRecorder`
  *instance* the launch task has no reference to (`AudioRecorder.swift:23`). The
  "never the recorder's current file" guard is not implementable where the sweep runs
  (Codex).
- **Jetsam defeats the age window.** Start a take, background the app, come back 25
  hours later to an app the OS has killed: the file is unreferenced, older than the
  window, and `currentFileName` died with the process. Both guards pass; the recording
  is deleted (Gemini 3.1 Pro).
- **A fetch on one context is not the whole truth** (Gemini 3.7 Flash) — though this
  one is narrower than claimed: only `AudioRecorder.start` writes into the audio
  directory (`AudioRecorder.swift:81`), and CloudKit carries audio as `audioData`
  blobs, not files, so a synced-down capsule creates no file to sweep.

The asymmetry M17 identified has not changed: **the cost of the leak is disk space;
the cost of a wrong sweep is someone's recording.** Two of the three holes need an
app-scoped recording lease that survives process death — real work, and not this
milestone's subject.

**So M18 keeps counting and does not sweep.** `AudioOrphanAudit`'s
`theAuditDeletesNothing` test stays exactly where it is. The sweep moves to §11 with
the lease named as its price of entry.

### 4F. Deletion, and what "turning listening off" now means

Two semantics the first draft left unresolved (Codex, Gemini 3.1 Pro).

**A deleted capsule leaves its rejections behind.** `CapsuleDetailView.delete`
(`:495`) removes the row; nothing removes rejections keyed to its id, and they would
sit in the user's iCloud forever. Blind pruning is not the answer — CloudKit can
deliver a rejection before the capsule it belongs to, so "no capsule for this id" does
not mean "orphan". **So deletion prunes explicitly, at the one site that knows:**
`delete` removes the capsule's rejections in the same save, the way it already enqueues
a delivery-job cancel. Anything left after that is a sync-order artefact and stays —
counted by an audit, never swept, for exactly the M17 §4E reason.

**Consent withdrawal erases rejections too.** The Settings footer promises, in three
languages, that turning listening off "erases what it has already heard, everywhere"
(`SettingsView.swift:269`). A rejection row records that the classifier proposed a
particular label for a particular capsule — it *is* derived from what it heard, so
keeping it would make shipped copy untrue, which is rule 3.

**The cost, stated plainly rather than argued away:** turning listening off and on
again re-analyses the library and your rejections are gone. Rejections are rare and
deliberate, so this will be felt. The alternative is amending copy that is currently
true to carve out an exception, and this project's habit is to keep the promise and
pay the cost. **This is the one product call in M18 that Jason may want to overturn**
(§8).

### 4G. Do not let this become a field change

The promotion for `SoundRejection` is a **new record type**, which
`cloudkit-schema.sh status` can see. Nothing else about the tooling improved: the
export was believed to omit unindexed fields (M19 §4C found otherwise) and `promote`
still cannot deploy. So the sequence
is fixed and non-negotiable:

1. `-initializeCloudKitSchema` on a simulator signed into iCloud — **run it twice**;
   the first run after a sign-in loses the race with zone creation and still prints
   `cleaned up` (M17 §15A).
2. `cloudkit-schema.sh status` — confirms the type reached Development.
3. **CloudKit Console → correct container → Deploy Schema Changes… → read every
   expanded item.** The dialog is the only field-complete view that exists.
4. `status` again, reading Production back.

If step 3 shows a change to `CD_Capsule`, **stop** — this milestone adds no field, and
anything else appearing there is a finding, not a formality.

### 4H. The trap that is already set, in the file M18 must edit

`expected_types()` derives what Production should hold from the `Schema([...])` array
in `SoundpostModelContainer.swift:56` — today `Schema([Capsule.self,
ListeningConsent.self])`. Add `@Model final class SoundRejection` and forget that
line, and:

- the container never mirrors it, so CloudKit never creates the record type;
- `expected_types()` never lists it, so `cloudkit-schema.sh` compares only what *is*
  listed and reports **green**;
- `CloudKitSchemaSeed` iterates `container.schema.entities`, so it has nothing to seed
  and — worse — when a seed row *is* missing it prints a line and `continue`s
  (`CloudKitSchemaSeed.swift:70`), still ending with `cleaned up`;
- `CloudKitSchemaTests.theShippingSchemaContainsBothEntities` asserts
  `contains("Capsule")` and `contains("ListeningConsent")` (`:45`) — a containment
  check, which a third entity cannot fail.

Four gates, all green, feature silently not syncing. **This is the same shape for the
tenth time, pre-positioned in the exact file this milestone has to change** — found by
Gemini 3.1 Pro and independently by Codex, and verified here.

**So S1 builds the guard before S2 writes the model.** A check that reads what *should*
exist: every `@Model` declared under `Soundpost/Models/` must appear in
`productionSchema`, and the seed must **fail the run** rather than `continue` when it
has no row for an entity. Both control-tested — add a throwaway `@Model`, watch the
guard go red, remove it.


---

## 5. Work breakdown (sequenced; each step compiles + passes + commits)

**S0 — the reveal stops asserting a guess (§4D).** No schema, no rejection yet. Remove
`soundPhrases` from the summary prompt and instructions (including rule 5), and render
`SoundprintDisplay.sentence` on the reveal beneath the summary. *First, because it needs
nothing from CloudKit and it is M17's own unfinished business.*
*Tests:* the prompt built for a capsule with sounds contains none of them; a capsule
with no note and no place yields no sentence at all; the reveal's attributed line is
produced for a capsule that has showable labels and not for one that does not.
*Watch:* test the **prompt and the policy**, never the model. Apple Intelligence is
absent on most devices and every caller already handles `nil`.

**S1 — the guard that must exist first (§4H).** Every `@Model` under `Soundpost/Models/`
appears in `productionSchema`; the seed fails rather than `continue`s on a missing row;
the schema test compares sets rather than asserting membership of two known names.
*Tests + control:* add a throwaway `@Model`, watch each of the three go red, remove it.
*Why before S2:* because S2 is precisely the change this trap is set for.

**S2 — the rejection row (§4A).** `SoundRejection` + a store whose winner, settlement,
compaction and tie-break are all **per `(capsuleID, identifier)`**, and whose save
failure restores every row it touched. Then §4G's human CloudKit sequence.
*Tests:* a newer answer supersedes an older one for the same key and not for a
different one; an undo wins; a future-dated row is clamped, not obeyed; an unorderable
tie resolves to rejected; rows do not accumulate under rapid toggling; a failed save
leaves the table exactly as it was.
*Watch:* every one seen to fail first. The consent suite is the shape to copy and
**not** the logic — see §4A.

**S3 — saying no (§4A).** On the detail screen, where the chips already are: dismiss a
phrase, and take it back. Nothing on the card — one line, no room for a decision.
Deletion prunes a capsule's rejections in the same save (§4F).
*Tests:* the policy layer as a pure function; deleting a capsule removes its rejections.
*Watch:* no UI-test target exists. Assert on the policy, verify the affordance by hand.

**S4 — everything that must honour it (§4B/§4C).** Remove the zero-argument
`showable*` APIs so the compiler enumerates the call sites, then visit all seven.
Thread a `RejectionIndex` from one UI query for the gallery, and one scoped fetch each
for `RemoteChangeReconciler` and `CapsuleBulkExporter`. A rejection re-syncs
notifications and discards an in-flight reveal generation.
*Tests:* one per surface — card, detail, search, facet, export, notification lead,
reveal — each seen to fail without the fix. Plus the negatives: the backfill and
remediation are unaffected, and consent withdrawal erases rejections (§4F).
*Watch:* do not fetch per capsule; do not resolve winners inside `body`.

**Drop order if tight:** S0. **Never drop:** S4 after S3 — a rejection the user can
make that search still ignores is worse than no rejection at all. **Never reorder:** S1
before S2.

## 6. Privacy / legal delta

**A new entity, and it needs stating rather than waving through.** `SoundRejection`
stores a capsuleID, a classifier identifier, a flag and a timestamp in the user's own
private database. It is derived from their own action, not from their recording, and
it is strictly *less* revealing than the soundprint it qualifies. No new data category,
nothing new transmitted, no third party.

`PrivacyInfo.xcprivacy` unchanged — verify rather than assert. The ASC nutrition label
is server-side state nothing in this repo can read and has been an open check since
M15 §11A#12; it is Jason's, and it is now genuinely worth doing because M18 adds an
entity for the first time since M15.

New UI copy is EN·JA·ZH-Hans in the commit that introduces it. Note the localization
gate's two known blind spots (M17 §14B/§15A): interpolated literals are matched by
*shape* only, so a two-argument key must be written non-positionally (`%@`, `%lld`) to
match at runtime; and a ternary inside `Text(…)` is in a position the gate does not
scan — put varying copy in a `LocalizedStringKey` property.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A rejection is lost to CloudKit LWW | §4A: immutable rows, the shape `ListeningConsent` proved |
| Consent's *logic* copied where it does not fit | §4A: winner, settlement, compaction and tie-break all scoped per key |
| A background pass resurrects a rejected label | §4C: backfill and remediation never see rejections; filtering is at display |
| A consumer is missed | §4B: the zero-argument APIs are **removed**; the build fails until all seven are visited |
| Rejection never reaches CloudKit at all, greenly | §4H: the guard, built in S1, before the model exists |
| Winner resolution lands on the 20 Hz path | §4B: a prebuilt `RejectionIndex`, one scoped fetch per non-UI path |
| A stale lock-screen body or reveal outlives the rejection | §4C: re-sync notifications, discard in-flight generation |
| Rejections outlive their capsule, or outlive consent | §4F: pruned at delete; erased with consent, and the cost is stated |
| A generated sentence asserts a guess | §4D: the guess never reaches the generator; nothing rests on a validator |
| A sweep deletes a live recording | §4E: **not shipped.** Three reviewers, three holes |
| A test passes without exercising the fix | Every new test run against the pre-fix code and seen to fail (M15 §11P) |

## 8. Human-in-the-loop checklist (needs Jason)

0. **One product call, and it is yours (§4F).** M18 erases rejections when listening
   is turned off, because the Settings footer promises erasure "everywhere" and a
   rejection row does encode a label the classifier proposed. The cost: an off/on cycle
   loses every rejection the user made. The alternative is amending copy that is
   currently true. **Say if you want it the other way** — it changes §4F and one test,
   nothing else.
1. **The CloudKit sequence in §4G** — the Console deploy is not automatable.
2. **Confirm M10 end to end.** 1.7.0 is live with `DeliveryIdentity` in Production for
   the first time. Watch `device_tokens` and `notification_jobs` gain rows. Their
   emptiness is the only reason the defect was ever found; their filling is the only
   proof it is fixed.
3. **The cold-launch deep link on a real device** — unverified since M17, changed
   twice since.
4. **One human hour in App Store Connect** for the two `MISSING_METADATA` IAPs.
   `unset ASC_APP_ID` first — `~/.zshrc` points it at CLI Pulse Bar (M17 §14F).
5. **The ASC privacy nutrition label** (§6).
6. **The store listing** — still no mention of listening or search, screenshots from
   1.1.0, now three releases stale.
7. **`* 2.swift` / iCloud Drive** — the repo still lives where conflict copies appear
   and break the build.

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| Immutable append-only rows, latest wins, clock-clamped | `ListeningConsent` + `ListeningConsentStore` |
| Why a mutable synced row loses an answer | `ListeningConsentStore.set`'s doc comment |
| The one seam every label consumer reads | `Soundprint.showable()` |
| Display policy as a pure function | `SoundprintDisplay` |
| Threading a decision instead of fetching it | `listening:` / `hasStanding` |
| Identifier-not-phrase matching | `GalleryFilter.soundFacetMatches` |
| Output validation that already rejects | `SoundSummaryWriter.looksLikeTheSameScript`, the anchor check |
| The unreferenced-file set | `AudioOrphanAudit.orphans` |
| A recorder that can be put in flight without a microphone | `AudioRecorder.beginRecordingForTesting` |

---

## 10. Acceptance criteria

- A wrong label can be dismissed from the capsule it is on, and taken back.
- The dismissal survives a sync, a gate bump and a re-analysis. It does **not** survive
  turning listening off — deliberately, and stated in §4F.
- It is honoured on all seven surfaces — card, detail, search, facet, export, lock
  screen, reveal — with one test each, every one seen to fail without it.
- The backfill and remediation are provably unaffected.
- The reveal never states a heard sound as certain, because it is never given one; the
  attributed line is there instead.
- Deleting a capsule takes its rejections with it.
- **A `@Model` missing from `productionSchema` fails the build or a gate** — verified
  by adding one and watching it go red.
- Standing bars green at every commit. **No new field on any existing record type.**

## 11. Out of scope / next

- **The orphan sweep**, whose price of entry is now named: an app-scoped recording
  lease that outlives the process, so "is this file live?" is answerable from a launch
  task holding no `AudioRecorder` at all (§4E). Until that exists, the audit counts.
- **A field-aware `cloudkit-schema.sh`** — still unbuilt, and now the thing standing
  between this project and any field-shaped feature (`sealedAt`, per-capsule anything).
  It needs to read the Console's own view or accept that no CLI can.
- **Gallery performance**, with a real large-library fixture — nothing in the suite
  seeds more than a handful of capsules, so every performance claim so far is
  unmeasured. Codex asks for thousands of capsules *and* rejections; that fixture is
  this milestone's most likely follow-on, and the thing that would turn §4B's
  `RejectionIndex` from an argument into a measurement.
- **Identifier migration.** Rejections key on the classifier identifier. If the
  vocabulary ever renames one, those rejections stop matching — silently, and in the
  direction that shows a label again (§4A).
- The acoustic almanac / "a year ago today"; an App Intent for capture; `sealedAt`.
- **Overdue and not a milestone:** the store listing and screenshots.

---

## 12. Review record (2026-08-29)

Reviewed by **Codex**, **Gemini 3.1 Pro** and **Gemini 3.7 Flash**, each independently
and each asked to be adversarial. All three agreed the subject is right. All three also
found the first draft's *mechanisms* wrong, in ways that changed the plan rather than
decorating it. What follows is what they found, and what did not survive contact.

**Unanimous, and the draft was wrong on both:**

- **The validator in §4D could not have worked.** All three said, in different words,
  that "asserts" versus "hedges" is not a lexical property, and certainly not one that
  survives EN·JA·ZH-Hans. The design changed rather than being strengthened: the guess
  never reaches the generator at all, and the attributed sentence is rendered beside
  what it writes.
- **The orphan sweep is still not safe (§4E).** Three reviewers found three *different*
  holes — no recorder reference at the launch site (Codex), jetsam defeating the age
  window (3.1 Pro), cross-context truth (3.7 Flash). Cut, with the missing precondition
  written down in §11 so the next attempt starts from it.

**Codex's sharpest** was a hole in the plan rather than in the code: the draft claimed
one seam and therefore free inheritance. `ResurfaceView.swift:161` calls
`showablePhrases()` directly, and the draft's own step list omitted it — so the
milestone whose purpose is to keep a guess out of generated prose would have fed it
one. The remedy is the strongest form of §11P available: delete the zero-argument APIs
and let the compiler produce the inventory.

**Gemini 3.1 Pro's sharpest** was that this project's recurring shape — *a check that
iterates an artefact cannot fail for what is missing from the artefact* — is **already
set** in the very file M18 must edit. A `@Model` left out of `Schema([...])` is
invisible to the schema gate, the seed and the schema test simultaneously. Codex found
it independently, and added the seed's `continue`. Verified here; it is §4H, and S1
exists because of it.

**Recorded so the record cuts both ways — two claims that did not hold:**

- 3.7 Flash worried CloudKit-synced audio files could race the sweep. Only
  `AudioRecorder.start` writes into the audio directory, and CloudKit carries audio as
  `audioData` blobs — no file is created by a sync. The sweep is unsafe for the other
  three reasons, not this one.
- 3.1 Pro said the plan had no compaction strategy. It did. The real defect was that
  compaction, like the winner and the tie-break, had to be scoped **per key** — which
  is the finding that survived and is now in §4A.

**Considered and not adopted:** 3.7 Flash's suggestion to keep §4D's prompt
instruction and lean on it. An instruction is a request. This milestone needed a
guarantee, and withholding the input is the only one on offer.
