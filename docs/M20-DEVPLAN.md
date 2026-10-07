# M20 — "Kept promises, more ways in"

> Status: **PLAN, approved** (2026-10-07). Drafted after a four-sweep discovery pass (backlog,
> code health, real-world signals, product) and a three-candidate / two-judge scoping pass, then
> reviewed in four rounds by Gemini 3.1 Pro and Gemini 3.8 Flash via `agy`, every finding checked
> against the code by an independent verifier — §12 records what they found, what was rejected and
> why, and what changed. Both approve. Plan written at `f465536`; 1.9.0 (build 20) **live since
> 2026-10-07**.

---

## 0. Goal & success statement

Soundpost has shipped most of its founding brief, and almost nobody uses it yet: over the last
90 days Sentry saw **45 sessions from 38 installs**, a visible share of them App Review's own
virtual devices, and the App Store shows **0 ratings and 0 reviews**. Two things follow.

1. **The promises the app already makes are the product, and three of them are unverified or
   untrue in edge cases.** "Seal it for five years and we'll tell you" rests on a far-future
   delivery path nobody has ever watched work end to end. A failed save, seal or delete is
   shown to the user as success. A sound analysis that failed part-way is stored as the final
   answer "nothing heard". And the release tooling that ships all of this could, until this
   morning, release the *wrong app* from Jason's own terminal.
2. **There is one door into capture, and the app's lead feature is hidden behind a second
   screen.** Capture starts only from the in-app "+" (PROJECT.md §1c names capture frequency
   as the existential risk). Sealing — the first thing the store listing promises — exists only
   as a button on an already-saved capsule's detail screen; onboarding never mentions it.

**M20 makes the existing promises true, then opens two doors:** seal at the moment of capture,
and start a capture from Siri, Spotlight, Shortcuts, the Action Button or the Home Screen icon.
No new CloudKit field or entity, no new target, no new dependency, no Pro change.

**Success** — all of these hold for the 1.10.0 build:

- A read-only Supabase query shows a `production` row in `device_tokens` and a delivered row in
  `notification_jobs` for a seal made on an **App Store** build, and Jason saw the push arrive.
  (If it does not, M20 becomes the fix for that, and S4–S5 move to M21 — §5.)
- `asc.py` cannot write to an app whose bundle id is not `com.soundpost.Soundpost`, cannot
  release a version other than `MARKETING_VERSION`, and cannot cancel a rejected
  (`UNRESOLVED_ISSUES`) submission — the move that made build 19's review thread read-only —
  without `--force-cancel`. `build-upload-asc.sh` refuses a dirty tree, iCloud `* 2.*` copies,
  a locked keychain, a build number that is not new, and an upload without dSYMs, unless one
  loud override is used; it tags what it uploads.
- No caught write failure in capture, seal, unseal or delete leaves a duplicate, ghost,
  file-less or falsely-sealed capsule, or a cancelled far-future push for a capsule that still
  exists; the user is told and stays where they were.
- A failed sound analysis is retried a bounded number of times instead of being stored as
  "nothing heard"; overlapping notification reconciles converge on the latest plan, and the
  M19 §4D-ii 64-slot baseline is unchanged.
- A capture can be sealed from capture review, and onboarding says, quietly, that a capsule
  can be sent forward.
- "New capsule" opens from an App Shortcut and a Home Screen quick action, from cold and warm
  launch, to an **idle** capture screen — never past unfinished onboarding, never recording on
  its own. Jason confirmed this on a device from a killed app.
- Standing bars at every commit (§1.7).

**Not success:** a green suite over the same write paths (no test exercises a failing save
today); a delivery "confirmed" from the dev-signed build on js (a Debug build registers APNs
`development`, `PushTokenSync.swift:32-37`); an intent that works only when the app is already
running; a seal-at-capture release shipped before the delivery witness.

---

## 1. Non-negotiables (carried from PROJECT.md / M9–M19)

1. **Calm, honest, literal copy.** Every sentence the app or listing says is literally true of
   the build (M19 §1 rule 3). The seal is an honor-system hold, not encryption — the copy says so.
2. **No counters, streaks, nags or engagement prompts.** No new notification kind.
3. **Free stays free; Pro stays hidden.** `ProOffer.isOnSaleInThisBuild` stays `false`
   (`ProGate.swift`). No Pro affordance, door, or string reachable by anyone — owners included
   (M19 §8-iii). Changing that is Jason's decision (§8 D1), not M20's.
4. **No new CloudKit field or entity; no Console deploy.** (`sealedAt` is M21+.)
5. **No new target** (widget, extension, Watch, UI-test), no App Group, no entitlement, no
   deployment-target raise (stays iOS 17.0).
6. **Delete no audio** except the user's own explicit delete; the orphan audit keeps counting only.
7. **Standing bars at every commit:** warning-free on CI's Xcode (26.6) **and** on a clean,
   non-incremental local Xcode 27 build (`check-warnings.sh` passes vacuously on incremental
   builds); all tests green with the executed count confirmed, not the exit code; i18n
   EN·JA·ZH-Hans 100%; zero new dependencies; CI green on the pushed commit (`gh run list` —
   CI was red for five days in M19 while every local run was green). Every new test is run
   against a deliberately broken implementation and **seen to fail**; snapshot with `cp`, never
   `git checkout`; record which mutation produced which failure. Commit with the attribution
   trailer the harness specifies.

---

## 2. Scope

| Step | What | Size | Human step |
|---|---|---|---|
| **S0** | Far-seal delivery witnessed on an App Store build (+ cold-launch deep link, reinstall restores audio) | S | **Jason, day 1, in parallel** |
| **S1** | Release tooling refuses the wrong app, version, cancel, tree and an unsymbolicated upload; CI refuses a zero-test run | M | none |
| **S2** | Every user write lands or rolls back where the user can see it | S–M | none |
| **S3** | Silent wrong answers become retryable or impossible (analysis failure, reconcile overlap) | M | none |
| **S4** | Seal at capture review + one onboarding line | M | release gated on S0 |
| **S5** | More ways into capture: App Shortcut + Home Screen quick action via one tested route | M | Jason, device check |
| **S6** | 1.10.0 release: notes, listing where literally true, final gates, submission | S | Jason says release |

**Drop order if tight:** S3's Sentry dedupe → S2's bulk-export tmp cleanup → S5's quick action
(keep the App Shortcut) → S5 → S4. Never drop S1 or S2 — every later step ends in a
submission, and S4/S5 send more traffic through exactly the write paths S2 fixes.

---

## 3. Current state (grounded 2026-10-07 — re-verify before you change)

- **Release:** 1.9.0 build 20 live. `MARKETING_VERSION 1.9.0`, `CURRENT_PROJECT_VERSION 20`.
  634 tests in 83 suites, 0 warnings, i18n 100% across 346 strings, CI green.
- **asc.py** — `f465536` already reads `SOUNDPOST_ASC_APP_ID` (not the generic `ASC_APP_ID`,
  which `~/.zshrc:68` exports for CLI Pulse Bar and which CLI Pulse's own scripts still need)
  and checks the bundle id before the first write. Still open: `cmd_release` picks
  `pending[0]` by state alone; `CANCELABLE` includes `UNRESOLVED_ISSUES` and `cmd_submit` calls
  `cmd_cancel()` unconditionally, so `resubmit` after a rejection kills the review thread;
  `ios_versions()` asks for `limit: 10`, unsorted, and 11 versions now exist; `cmd_screenshots`
  deletes old images before uploading new ones. There is no test of any of it.
- **build-upload-asc.sh** hard-codes `PROJECT_DIR="/Users/jason/Documents/Soundpost"` (line 17);
  a failed dSYM upload is a warning (line ~91) — 1.6.1 and 1.6.2 have no dSYMs in Sentry; no
  preflight; `git tag` is empty.
- **CI** gates on the `** TEST SUCCEEDED **` marker only (`ci.yml:101`), which a zero-test run
  prints. It runs Xcode 26.6 on `macos-26` and asserts nothing about the version.
- **Capture save** — `CaptureViewModel.save` calls `store.create()` (line 258) before
  `markRecording`/`markCaptured`/`save` can throw; the retry in `CaptureView` starts with
  `try? store.save()` (line 509), committing the failed attempt's row.
- **Detail writes** (`CapsuleDetailView.swift`): `seal(until:)` (561) logs a failure and then
  dismisses or shows "sealed — reminders off" as if it had sealed; `unseal()` (603) logs and
  moves on; `delete()` (614) enqueues the server cancel first (deliberate, §S4 durability),
  deletes the audio file (623) **before** the store delete is known to succeed, fires
  `cancelJob` (635) and dismisses (636) regardless.
- **`ModelContext.rollback()` does not restore already-materialised objects** — recorded in
  `CapsuleStore.swift:195`, `SoundprintBackfill.swift:119`, `SoundRejectionStore.swift:237`.
  Every S2 fix restores by hand and every S2 test asserts the in-memory object as well as the
  store.
- **Analysis** (`SoundprintService.swift`): `await analyzer.analyze()` (120) discards its
  result; the observer's `request(_:didFailWithError:)` (148) is empty; an empty result is "a
  legitimate, terminal answer" (90). The backfill only retries `.skipped(.failed)`.
- **Reconcile** (`NotificationScheduler.reconcile`, 101–158): snapshots pending ids, removes
  stale ones, then awaits each `center.add` with nothing serialising it; 11
  `notifications.sync(` call sites. Swift actors are reentrant across `await`, so "make it an
  actor" would look serialised and not be.
- **Seal entry points:** only `CapsuleDetailView`'s "Seal to the future" (≈241). Capture review
  sections: Mood, Sounds like, One line, Place, Echo (`CaptureView.swift:258–298`). Onboarding
  pages: "Capture how this moment sounds", "Remember where you were", "Hear today again,
  someday" (`OnboardingView.swift:37/47/64`) — none mentions sealing.
- **Capture entry points:** the toolbar "+" and the empty-state button in `ContentView`. No
  `AppIntent`, `AppShortcutsProvider`, `NSUserActivity` or `UIApplicationShortcutItems` exists.
  The SDK marks `openAppWhenRun` deprecated at iOS 26.0 in favour of `supportedModes`
  (iOS 26.0+; `AppIntents.swiftinterface:3100–3107`) — invisible at the 17.0 target.
- **The cold-launch trap is documented:** a pending request set before any body evaluates used
  to be dropped (`ContentView.swift:600`, `drainPendingDeepLink` at 610;
  `CapsuleOpenRoute.PendingLink` at 34). Onboarding swaps the root on
  `hasCompletedOnboarding` (`SoundpostApp.swift:258–261`).
- **Delivery:** `SupabaseDeliveryBackend.swift:9–11` and `SoundpostApp.swift:18–22` still say
  the path is "empty until deployed / inert in production"; the live URL is at 21–22 and
  `isConfigured` is always true. Those comments are what the next agent will believe.
- **js** still runs the dev-signed, Production-pinned build from the 2026-09-05 sync test.

---

## 4. Design decisions

### 4A. S0 — the delivery witness is a gate, not a step

No doc since M18 §8.2 records a row in `device_tokens`. M20's S4 *invites more people to seal*,
so the "we'll notify you on <day>" promise (`SealSheet.swift`) must be seen working before the
release that ships S4 — **the witness gates the release, not the commit.** It is safe to run
now: `CD_serverJobSyncedAt` is in Production (`docs/cloudkit-schema/PRODUCTION.ckdb`), so a
two-device user no longer gets duplicates.

Procedure (Jason, with the agent preparing the exact read-only SQL in this section's
build record):
1. **First** look up `delivery_optouts` for the witness account's `user_key`. One tombstone row
   already exists (`backend/supabase/migrations/0001_m10_delivery.sql:81–100`); if it is
   js's account, registration is refused and the test reads as "broken" for the wrong reason.
2. On js, confirm iCloud sync has finished, **then** uninstall the dev-signed build (M19 §8-i:
   switching environments without uninstalling once exported a Dev seed row into Production).
3. Install 1.9.0 from the App Store. In the calendar, seal a capsule to **the day after
   tomorrow** (not a Quick pick — "In 1 month" also creates rows but puts step 5 a month away).
   The picker is date-only and the seal fires at 09:00 on that day (`CapsuleStore.humaneInstant`
   → `SealClock`), so it is ~33–57 h out. *Tomorrow* is inside `SealDeliveryRouter.localHorizon`
   (24 h) once you seal after 09:00: the seal stays local-only and **no** `notification_jobs` row
   is ever written — a false "broken".
4. Straight away, read-only counts in Supabase project `gkjwsxotmwrgqsvfijzs` (production —
   reads only): `device_tokens` by `environment` (expect a `production` row), `notification_jobs`
   for that capsule id. Then **do not open Soundpost on any device signed in to that iCloud
   account from 09:00 the day before the seal until the push arrives**: a sync inside the last
   24 h hands the seal back to a local notification and cancels the server job
   (`SealDeliveryService.swift:86–99`), and on the lock screen the two look identical.
5. After the push, re-run the `notification_jobs` query: the row must read `status = 'sent'`. If
   the row is gone, the job was cancelled and the local backstop fired — redo the witness; that
   is not a server failure. Then, from a killed app, tap a resurface notification (the
   cold-launch deep link, unverified since M17 §13C) and optionally delete + reinstall to confirm
   audio is restored from iCloud (unverified since M9 §8).

Agent part: fix the two stale comments; write the queries; record the outcome here. **If no
rows appear,** S0 becomes the investigation and S4–S5 move to M21.

### 4B. S1 — guards with tests that CI can run without packages

`asc.py` imports `jwt` and `requests` at load, so CI's stock Python cannot import it. Move the
pure decisions into `scripts/asc_policy.py` (stdlib only) and test them with `unittest`:

- `assert_app_identity(bundle_id)` — already wired as `assert_soundpost_app` in `asc.py`; move
  the decision into the policy module and test it.
- `releasable(versions, marketing_version)` — exactly one `PENDING_DEVELOPER_RELEASE` version
  whose `versionString == MARKETING_VERSION`, else refuse with the states listed.
- `may_cancel(state, force)` — `UNRESOLVED_ISSUES` only with `force=True`. `resubmit` stops
  calling cancel on a rejected submission and prints the path that keeps the thread:
  `asc.py attach N` → reply in the App Review thread → **Update Review** on the version page →
  **Resubmit to App Review** (M19 §8-iii).
- `pick_version(versions, version_string)` — and fetch with `filter[versionString]` instead of
  `limit: 10` unsorted.
- Screenshots: upload and verify the new set, then delete the old (a failure part-way must not
  leave a locale empty).

`build-upload-asc.sh`: derive `PROJECT_DIR` from the script's location; one preflight with one
override (`RELEASE_PREFLIGHT_OVERRIDE=yes`, modelled on `CK_SKIP_SCHEMA_CHECK`) — clean tree,
no `* 2.*` files under the repo, the keychain probe from the global notes
(`security show-keychain-info` + one-second `codesign` of a temp binary), build number greater
than the newest in ASC, `SENTRY_AUTH_TOKEN` present; dSYM upload fatal in upload mode under
the same override; `git tag v<version>-b<build>` after a successful upload.

CI: a step **"Release-tooling policy tests"**, with the offline gates before the simulator is
chosen, runs `python3 -m unittest discover -s scripts -p 'test_*.py' -v > py-tests.log 2>&1 ||
{ cat py-tests.log; exit 1; }`, then `cat py-tests.log`, then fails unless
`grep -Eq '^Ran [1-9][0-9]* tests?' py-tests.log`. Not a bare `python3 -m unittest`: `scripts/` is
not a package, so it finds 0 tests, and on Python < 3.12 that still exits 0. Not through `tee`:
the default `run` shell has no pipefail. Because CI cannot import `asc.py`,
`scripts/test_asc_policy.py` also reads `asc.py`'s **source** (the `ProOfferTests` pattern) and
asserts that the bundle check, `releasable`, `may_cancel` and `pick_version` are called from it
and that `UNRESOLVED_ISSUES` is not in its cancel set — so a control applied to `asc.py` itself
fails in CI too. Then: an executed-test-count floor (fail if `Test run with N tests` is missing
or `N < 634`, the floor raised only deliberately); print **and assert** the Xcode version the job claims;
`TestSupport.freshStore` also clears `SoundRejection`; pin the curated vocabulary's identifier
set so a rename fails until a migration ships with it.

Every guard is seen red against a control (put `UNRESOLVED_ISSUES` back into the cancel set;
drop the bundle check; pick `pending[0]`; set the floor to 0; delete or rename
`test_asc_policy.py` — the Python step must go red on 0 tests).

### 4C. S2 — one testable home for the four write paths

There is no UI-test target, so the logic leaves the views. A `CapsuleActions` (or methods on
`CapsuleStore` plus a small coordinator) owns seal, unseal, delete and capture-save, each
returning a result the view renders: on failure, **restore the in-memory capsule by hand**,
show one calm static-string alert (EN/JA/ZH-Hans), and **do not dismiss**.

- **Capture:** create the row only once everything that can throw before it has succeeded, or
  delete it by hand on failure; the retry must not begin by committing the failed attempt
  (`CaptureView.swift:509`, `try? store.save()`). Also move `SoundAnalysisPreferences.hasRecordedHere
  = true` and `hasStanding = true` (`CaptureViewModel.swift:284/288`) to **after** `store.save()`
  succeeds — move them only; never write `false` on failure (both are monotonic, and a reset could
  revoke standing the launch path granted). The save-throws test runs inside
  `TestSupport.withIsolatedListeningPreference` and asserts both flags still false after the
  failed save and true after the successful retry.
- **Seal:** no "sealed — reminders are off" alert after a failed seal.
- **Delete:** keep `DeliveryPreferences.enqueuePendingCancel(capsuleID)` **first** (that order
  survives a cold launch, §S4), with no `await` between it, `store.delete` and `save()`. Remove the
  audio file and fire `cancelJob` only after the save succeeds (`cancelJob` resolves the queue
  entry on server confirmation). On a caught save failure, undo the pending `context.delete` of
  the capsule **and** of its `SoundRejection` rows (by hand or `rollback()` — prove a later
  unrelated `save()` does not commit them), then call the existing
  `DeliveryPreferences.resolvePendingCancel(capsuleID)` (idempotent; add no new API).
- **Close the pre-existing kill window too.** Today, a crash between the enqueue and the save
  leaves a far seal with `serverJobSyncedAt` set; the next launch's `drainPendingCancels`
  (`SealDeliveryService.swift:121–129`) cancels its server job unconditionally, the upsert loop
  skips it (`serverJobSyncedAt != nil`, :75) and the planner schedules no local reminder
  (`NotificationPlanner.swift:59`) — it never notifies. So `drainPendingCancels` decides each
  queued id from a **fresh fetch by id** on the main context (passed into `reconcile` from
  `NotificationCoordinator.sync`'s context): still in the store → resolve without cancelling (the
  delete never committed; the normal diff owns that job); absent → cancel, resolve only on
  success; fetch error → leave queued. **Never** decide from the `capsules` argument: it can be a
  pre-delete snapshot from a sync already in flight, or `[]` from `(try? store.all()) ?? []`.
- **Bulk export (drop-able):** `CapsuleBulkExporter` leaves the uncompressed folder beside the
  zip in tmp; adopt the `VideoExportWorkspace` pattern (unique dir, cleanup, launch scavenge).

Tests use a store whose `save()` throws and assert both the stored state and the in-memory
object. Delete tests also assert `!DeliveryPreferences.pendingCancelCapsuleIDs.contains(id)` after
a failed delete (pattern: `SealDeliveryTests.swift:193`); that a pending cancel for a capsule
still in the store, after `reconcile`, cancels nothing, resolves the entry and leaves
`serverJobSyncedAt` unchanged; and that a stale array still holding a capsule already deleted from
the store still gets its job cancelled. Controls: skip the restore; dismiss anyway; move the file
delete back before the save; skip `resolvePendingCancel`; skip undoing the pending delete; drop the
existence check in `drainPendingCancels`.

### 4D. S3 — silent wrong answers

- **Analysis:** record the observer's `didFailWithError` and return `.skipped(.failed)` through a
  pure outcome function. **Do not** build this on `analyze()`'s `didReachEndOfFile`: the
  iOS 27 SDK header says "any errors produced during analysis will flow downstream to the
  request observers" and the flag is NO only after `cancelAnalysis`, which Soundpost never
  calls (`SNAnalyzer.h:117–118`, checked 2026-10-07). The observer is where failure arrives. Bound retries outside the schema:
  a per-capsule attempt count in an injectable `UserDefaults` (a suite per test), keyed by
  `Capsule.id`, cap 3.
  - **What counts:** every "could not listen to this clip on this device" result — `.skipped(.failed)`
    **and** `analyse` returning `nil` (no readable audio, or `WaveformExtractor.extract` throwing,
    `SoundprintBackfill.swift:181,188`), which is where a corrupt clip fails today, unbounded.
    **Not** `.notPermitted`, cancellation, or a batch dropped because consent was withdrawn.
    The count is removed when the capsule is written.
  - **A capped capsule stays `nil`.** Do **not** write the empty marker: empty means "analysed,
    nothing to say" (`Capsule.swift:47–50`), export would turn it into `soundsHeard: []`
    (`CapsuleBulkExporter.swift:172–181`), and `soundprintRaw` syncs, so one device's local count
    would become an account-wide verdict.
  - **The backfill pages past capped capsules.** The fetch becomes
    `$0.soundprintRaw == nil && !capped.contains($0.id)` (the `Set<UUID>.contains` form already in
    `SoundRejectionStore.swift:188`), with the plain predicate when the set is empty. Without it,
    once the newest 20 unanalysed capsules are all capped every batch writes 0, `drain` stops
    (`SoundprintBackfill.swift:73`) on every launch, and every older capsule goes unanalysed for
    good.
  - **Test:** `batchSize: 2`; the two newest capsules have unreadable audio, one older capsule a
    real clip; after cap + 1 drains the older one is labelled and the two newest are still `nil`.
    Control: drop the exclusion — the older capsule is never labelled.
- **Reconcile:** serialise or coalesce `reconcile` so the latest plan wins — e.g. one chained
  `Task` that a newer call supersedes. The interleaving test (two overlapping reconciles on a
  fake center) must fail against the current code **and** against an actor-only version. The
  M19 §4D-ii baseline in `AlmanacTests` must stay exactly equal; the edit-resync path must still
  rebuild bodies.
- **Sentry (drop first):** `CloudSyncMonitor` sends one message per sync error event (98 in
  8 minutes from one device) with only the outer `NSError.code`. Dedupe per (domain, code) per
  launch and add the domain and underlying `CKError` code as integers (the `StaticString` no-PII
  rule holds).

### 4E. S4 — seal at capture, quietly

Capture review's **Echo** section becomes a three-way choice: a surprise echo (today's
default), **seal until a date**, or off. Sealing replaces the echo, as it already does
(`CapsuleStore.seal` clears `echoAt` and `serverJobSyncedAt`; "Sealing supersedes any pending
echo", `CapsuleStore.swift:110`).

**Choosing "seal until a date" opens `SealSheet` as a modal sheet** from the review screen — a
third `.sheet` beside the echo picker (`CaptureView.swift:96`), not inlined into the review
`ScrollView`. Its presets and Cancel/Seal toolbar stay as they are. Two small API additions:
- `initialDate: Date? = nil`, so reopening from the review row shows the chosen date instead of
  resetting to +6 months (the detail call site, `CapsuleDetailView.swift:140`, does not change);
- its two `sealPromise` sentences move into one `static func … -> LocalizedStringKey` taking
  (date, canPromise), so the review row reuses the existing catalog keys and adds no strings.

The capture choice and its date are set **only** inside `onSeal`; Cancel leaves the previous
choice exactly as it was. **Authorisation is requested inside `onSeal`**
(`Task { await notifications.requestAuthorization() }`) — when the date is confirmed, the same
moment `CapsuleDetailView.seal` asks — **not** on selection and not at Save. So
`CaptureView.save()` and `CaptureViewModel.save` stay synchronous; capture gets no post-save
"sealed — reminders are off" alert; instead the review row shows SealSheet's
`canPromiseAReminder` sentence for the chosen date, honest once the answer arrives. `onSeal` does
not call `notifications.sync` (nothing is saved yet), and **neither does the save**: a capsule
saved sealed is a new id with `.sealed`/`sealUntil`, so it changes
`UpcomingResurfaces.sealSignature` and the gallery observer (`ContentView.swift:155–157`) syncs
it exactly as it already syncs the capture echo; if that sync is interrupted,
`serverJobSyncedAt == nil` makes the next launch or foreground reconcile upsert the job. Do not
copy `CapsuleDetailView.seal`'s `await sync` before `dismiss()`: it predates delivery, adds no
durability, and a second call races the observer's (§4D). Reword the now-false invariant at
`NotificationCoordinator.swift:43–46` and the `echoPromise` comment at `CaptureView.swift:437–439`
to: "capture's echo never asks; capture's seal option asks when its date is confirmed, as the
seal sheet does". `EchoPromiseTests` stays green unchanged.

**Order inside `save(using:)`:** `store.seal` comes **after** `markCaptured` **and after the echo
assignment** (today `CaptureViewModel.swift:295`, `capsule.echoAt = echoEnabled ? … : nil`), as
the last change before the single `store.save()` — never after the commit, so capture and seal
are saved, or fail, as one S2 write. The three-way choice also drives that assignment: `echoAt` is
written only for the surprise-echo option and is nil for seal or off, so the review state never
holds `echoEnabled == true` beside a seal. The time is normalised through `humaneInstant` /
`SealClock`.

Onboarding page 3 ("Hear today again, someday") gains **one** line naming both ways a capsule
comes back. No new page, no new permission prompt, and not a lead — PROJECT.md §1c warns
against leading with the future-self framing.

**Tests:** a capture saved with the seal option is `.sealed` with `sealUntil` normalised and
`echoAt == nil` — **seed the take the way a real one is** (`finishRecordingForTesting`, which draws
`echoAt`) with `echoEnabled` at its default; `setReviewStateForTesting` leaves `echoAt` nil and
passes against the bug. See it red with the `seal` call moved back to directly after
`markCaptured`; unsealing that capsule plans no echo. The seal row's sentence is the reminder
promise for `.notDetermined` and `.authorized` and the notifications-off variant for `.denied`
(`setAuthorizationForTesting`). The view model's seal choice is cleared by `reset()` and never
set without a date. For a fixed library the 64-slot plan changes only in that capsule's kind and
date, and the save changes `sealSignature`. Note for Jason: the rating prompt fires after a reveal
(`ContentView`, `ReviewPrompt`), so more seals mean more eligible prompts — once per version,
unchanged.

### 4F. S5 — capture doors through one route

- `OpenCaptureIntent` and an `AppShortcutsProvider` with EN/JA/ZH-Hans phrases in a string
  catalog under `Soundpost/` (the localization gate globs it). **Declare both mode witnesses, with
  no `#if` and no `check-warnings.sh` carve-out:** `static let openAppWhenRun: Bool = true` —
  iOS 17–25 read only this; never drop it — and `@available(iOS 26.0, *) static let
  supportedModes: IntentModes = .foreground` (a literal; the App Intents metadata extractor
  rejects anything else — confirm the case name in the SDK). `openAppWhenRun` is deprecated at
  iOS 26.0 and `supportedModes` introduced at 26.0 (`AppIntents.swiftinterface:3100–3107,
  3236–3250`), so Xcode 26.6 has both; Swift reports a versioned deprecation only when the
  deployment target is at or above the deprecated version, so at 17.0 neither Xcode warns —
  `CLGeocoder` (deprecated `ios(5.0, 26.0)`) already compiles warning-free in
  `LocationProvider.swift` the same way. Write `iOS 26.0`, not the SDK's `anyAppleOS 26.0`
  spelling. Do not gate on `#if compiler`: CI would then build a different intent from the one
  shipped. Confirm with a clean Xcode 27 `check-warnings.sh` run.
- A static `UIApplicationShortcutItems` "New capsule" entry (its title in `InfoPlist.xcstrings`),
  **handled by a scene delegate, not the app delegate.** Soundpost uses the SwiftUI scene
  lifecycle (`@main struct SoundpostApp: App`; `INFOPLIST_KEY_UIApplicationSceneManifest_Generation
  = YES`), under which `application(_:performActionFor:completionHandler:)` is never called — and
  the iOS 27 SDK deprecates it ("Use UIScene lifecycle and
  `windowScene(_:performActionFor:completionHandler:)`", `UIApplication.h:453`). So
  `SoundpostAppDelegate` gains (it has none today) `application(_:configurationForConnecting:options:)` returning
  a `UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)` whose
  `delegateClass` is a small `SoundpostSceneDelegate: UIResponder, UIWindowSceneDelegate`. This is
  the documented SwiftUI pattern (Apple Developer Forums thread 656997; SwiftUI forwards scene
  events to the supplied class and `WindowGroup` keeps rendering) — **the delegate must not create
  or assign a `UIWindow`** and implements only the two shortcut entry points. Because a reviewer
  (round 3) predicted a black screen from exactly this, the **first S5 commit that adds it is
  launched on the simulator** and must show the gallery and still route a notification tap
  (`NotificationCoordinator` is the `UNUserNotificationCenter` delegate, independent of the scene
  delegate); if either regresses, the quick action is dropped (it is first in the drop order). That delegate handles the **cold** launch from
  `UIScene.ConnectionOptions.shortcutItem` in `scene(_:willConnectTo:options:)` and the **warm**
  one in `windowScene(_:performActionFor:completionHandler:)`, which must call
  `completionHandler(true)` once the request is set; both only set the pending capture
  request on the same `@MainActor` owner as `pendingDeepLinkCapsuleID`, reached through one
  hook installed at app init. The device check covers both. If this costs more than it should,
  the quick action is first in the drop order — keep the App Shortcut.
- Both only set **one pending capture request**. A pure `CaptureLaunchRoute`, modelled on
  `CapsuleOpenRoute.PendingLink`, decides present / wait / none: wait through unfinished
  onboarding; never stack on an open capture sheet or reveal; drained after the gallery exists,
  like `drainPendingDeepLink`, so it cannot fall into the cold-launch trap.
- **The newest request wins, and a capture request and a notification deep link are never both
  live.** Setting the capture request clears `pendingDeepLinkCapsuleID`; a notification tap
  (`NotificationCoordinator.userNotificationCenter(_:didReceive:)`) clears the capture request.
  Keep the request on the same `@MainActor` owner as `pendingDeepLinkCapsuleID`, so "newest" needs
  no clock. This is the rule `openCapsule` already applies (`ContentView.swift:620–625`: the user
  going somewhere themselves supersedes a link still waiting). Presenting capture through the
  existing doors (toolbar "+", empty-state button) clears a waiting link too — a link left pending
  under the capture sheet would otherwise fire when its capsule imports, or when the user's own
  capture saves (`.onChange(of: capsules.count)`). So the route has no "both pending" case. On a
  cold launch at most one exists: both live in memory and come from one launch event.
- **Opens capture idle. Never records headless or in the background** (Info.plist declares only
  `remote-notification`); the nearby-voices notice stays on the idle screen. Starting a
  recording directly from an intent is §8 D2.
- No new target, entitlement or schema. Table-driven tests of the route, each case seen red
  against a control (ignore onboarding; consume the request before the gallery exists; keep both
  requests): (1) link waiting, then a capture request → link cleared, capture presents, and a
  later import of the linked capsule opens nothing; (2) capture request waiting (onboarding
  unfinished), then a notification tap → request cleared, and the link opens once the gallery
  exists.
- **Device check (Jason):** from a killed app and from the background — the Siri phrase, the
  Shortcuts app, the Action Button (supporting hardware), the Home Screen quick action; and run
  the intent once through Shortcuts on an iOS 17–25 runtime (the iOS 18.5 simulator runtime is
  installed): only that path reads `openAppWhenRun`. The simulator cannot press the Action Button.

### 4G. S6 — the release

`MARKETING_VERSION 1.10.0`, build 21. `metadata/*/release_notes-1.10.0.txt` in three languages,
copied to `release_notes.txt` (the gate requires the match). The description gains a line about
Siri/Shortcuts and sealing at capture only if both shipped; add `CLAIMS` entries for them only
then. The off-sale wording gate keeps applying (Pro stays hidden). Screenshots are re-run only
if a captured screen changed (capture review is not one of the four shots). A clean,
non-incremental Xcode 27 `check-warnings.sh` run before upload. Submit through S1's tools; the
release itself only on Jason's word.

---

## 5. Work breakdown (sequenced; each step compiles, passes and is committed)

1. **S0** starts day 1 (Jason) and runs in parallel; agent part lands with S1.
2. **S1** → **S2** → **S3** → **S4** → **S5** → **S6**.
3. S4 may be committed before S0 completes; **S6 does not upload a build containing S4 until
   S0 recorded rows.** If S0 fails: S0 becomes the fix; S4 and S5 are reverted from the
   release branch or deferred to M21, and 1.10.0 ships S1–S3.

---

## 6. Privacy / legal delta

- No new data collected or sent. App Intents expose no capsule content (no `AppEntity`,
  `IndexedEntity` or Spotlight items for capsules — notes, places and sounds stay out of the
  system index).
- The Sentry dedupe adds two integers (error domain enum, CKError code); no strings.
- Open for Jason (§8 D7): Sentry stores an IP-derived city (`user.geo`) while the project's
  IP-scrubbing setting is off; `PrivacyInfo.xcprivacy` declares no location. A settings change,
  possibly a label review — not code.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| S0 fails for a reason unrelated to code (the optout tombstone) | look up `delivery_optouts` first (§4A step 1) |
| Uninstalling js's dev build loses unsynced local data | confirm sync finished first |
| A naive `rollback()` leaves the in-memory capsule looking sealed | restore by hand; tests assert the object |
| Delete reorder breaks §S4 cold-launch cancel | enqueue stays first; on failure undo the pending delete, then `resolvePendingCancel`; the drain cancels only ids a fresh fetch shows are gone |
| Analysis retry loops on a corrupt clip, or capped clips starve older ones | per-capsule cap in UserDefaults; capped capsules stay nil and are left out of the backfill fetch; tested with more capped capsules than one batch |
| "Serialised" reconcile that is only an actor | interleaving test must fail against actor-only |
| 64-slot plan drifts | AlmanacTests baseline equality unchanged |
| Intent request dropped on cold launch / skips onboarding | one pure route, drained after the gallery; device check |
| Xcode-27-only warnings invisible to CI (26.6) | clean local Xcode 27 `check-warnings.sh` at every S5 commit and before upload |
| iCloud `X 2.swift` copies compile into the build (synchronized groups) | S1 preflight scans; never `git add -A` |
| Preflight blocks an emergency release | exactly one loud override |
| Shipped copy over-claims | release notes and listing edited only for what shipped; store-metadata gate |

---

## 8. Human-in-the-loop (needs Jason)

**Steps**
- **S0** delivery witness (§4A) — day 1.
- **S5** device check from a killed app (§4F).
- **S6** "release" — the only public, irreversible action.

**Decisions** (M20 assumes the default in **bold**)
- **D1 Pro:** **A keep hidden** / B sell lifetime-only (a first-IAP review with the binary; no
  annual product may remain referenced, since the review sandbox serves unsubmitted products —
  `docs/evidence/1.9.0-build18-review-paywall.png`) / C free the image+audio share card
  (one-way under "free stays free").
- **D2 Capture doors:** **open capture idle** / start recording immediately.
- **D3 Rating prompt:** **keep as is** (after a reveal, once per version) / remove.
- **D4 "Capture today" notification:** **no.**
- **D5 App Store Connect analytics report request** (one POST, aggregated opted-in data, no
  SDK): recommended **yes**, so M21 is not planned blind.
- **D6 Internal TestFlight group:** recommended **yes** — a channel for Production checks like
  S0 that is not a hand-signed build.
- **D7 Sentry:** turn on project-level IP/geo scrubbing; decide whether the privacy label needs
  a change.
- **D8 Dotfiles:** asc.py no longer reads `ASC_APP_ID`, so `~/.zshrc:68` can stay for CLI
  Pulse. Optional: put the `SENTRY_*` exports in `~/.zshenv` so agent shells can upload dSYMs
  without the `grep | eval` workaround.
- **D9 iOS 27 simulator runtime** (disk cost) — only if you want a local iOS 27 test run before
  submission.
- After release: resolve stale Sentry issues SOUNDPOST-1/-3/-4 (agents do not modify issues).

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| Pending-request routing that survives cold launch | `CapsuleOpenRoute.PendingLink`, `ContentView.drainPendingDeepLink` |
| Seal presets, honest copy, time normalisation | `SealSheet`, `CapsuleStore.seal`, `CapsuleStore.humaneInstant`, `SealClock` |
| Restore-by-hand after a failed save | `CapsuleStore` (≈195, "every field goes back by hand"), `SoundprintRemediation` (≈202, remember the originals). Not `CapsuleDetailView.write`, which calls `rollback()` — fine for an insert, wrong for a mutated object |
| Isolated store for async tests | `TestSupport.isolatedStore()` |
| 64-slot baseline | `AlmanacTests` (M19 §4D-ii) |
| One-override safety gate | `CK_SKIP_SCHEMA_CHECK` in `build-upload-asc.sh` |
| Source-reading guard tests | `ProOfferTests`, `SentryBootstrapTests.startInstallsTheScrubber` |
| Mutation harness pattern | M19 §8-ii (cp snapshot, restore, byte-compare, `-collect-test-diagnostics never`) |

---

## 10. Acceptance criteria

- §0 success list holds, with S0's rows recorded in this document.
- Every new test has a recorded control mutation that made it fail.
- CI green on the final commit; the executed-count floor is ≥ the final count.
- 1.10.0 submitted through the guarded tools; release on Jason's word.

---

## 11. Out of scope / M21

- **LaunchSequence extraction** — the privacy-critical launch order (consent → resync →
  standing → remediation → backfill) lives inline in `SoundpostApp`'s `.task` with no test; M21's
  first hardening item, as an order-only refactor with a fail-closed test.
- Xcode 27 in CI (when runner images ship it); the `CLGeocoder` → MapKit branch (changes place
  strings); a Swift 6 strict-concurrency re-measure (`docs/SWIFT6-TRIAL.md` dates from M12).
- Pro, whichever way D1 goes; the Pro theme-undo gap and disabled editors for sandbox owners;
  the dormant `loadProducts` retry.
- `sealedAt`; the orphan sweep (needs a recording lease); rejection identifier migration;
  correction discoverability; echo-arrival framing; anniversary or "capture today"
  notifications; widgets / Live Activities / Lock Screen controls / Watch / iPad.
- `hasRecordedHere`'s `hasCompletedOnboarding` seed grants listening standing on a phone set up
  as new once onboarding completes there, so the protection M15 describes lasts one launch —
  re-decide the seed (found by review round 1, Flash-6).
- **Far-seal "synced" stamp before the server confirms** (found by the M20 pre-upload review;
  pre-existing since M10). `SealDeliveryService.reconcile` sets `serverJobSyncedAt` *before*
  awaiting `upsertJob` (and clears it before `cancelJob`) as an in-flight debounce; an autosave
  can persist that claim, and a process killed before the request lands leaves a far seal
  stamped with no server job — no push and, because the planner then skips it, no local
  backstop. Fix: an in-memory in-flight set for the debounce, and stamp/clear only after the
  server answers, with a fresh check that the capsule still exists and is still a far seal.
  Test: a backend that never returns, then a fresh service on the same store must upsert again.
- Repo hygiene: the unmerged `release/1.6.x` branches (the §11L carve-out record lives only
  there — Jason wanted to revisit it in person), the stale August worktree, `build/` logs and
  the five copies of js's store in `build/js*`.

---

## 12. Review record

### Round 1 — Gemini 3.1 Pro (high) and Gemini 3.8 Flash (high), via `agy`, 2026-10-07

Both returned **APPROVE WITH CHANGES** (Pro: 3 findings; Flash: 9, one marked blocker). Neither
reviewer's word was taken: each finding went to an independent verifier that read the code (and
the iOS 27 SDK headers) and judged it REAL, PARTLY or WRONG, and whether the reviewer's own fix was
right.

| # | Finding | Verdict | What changed |
|---|---|---|---|
| Flash-2 | "Seal ≥ 25 h out" can be inside the 24 h local horizon (date-only picker, 09:00 normalisation) → no server row, false failure | **REAL, major** | §4A: day after tomorrow; plus a second trap the reviewer missed — any sync in the last 24 h cancels the server job and the local notification fires instead, so don't open the app; check `status = 'sent'` after |
| Flash-3 | Retry cap in UserDefaults while the backfill fetches the newest 20 `nil` → capped clips starve every older capsule | **REAL, major** | §4D: capped capsules stay `nil` and are excluded from the fetch (the reviewer's empty-marker option rejected: it would become an account-wide "nothing heard"); the cap also covers `analyse` returning `nil`, where corrupt clips fail today |
| Flash-4 | Enqueue-before-save + kill → surviving far seal loses its push forever | **PARTLY** — real, but **pre-existing since M10**, not M20's | §4C: `drainPendingCancels` decides from a fresh fetch by id (never from the `capsules` snapshot); failed delete undoes the pending delete |
| Pro-1 | Seal at capture would be overwritten by the trailing `echoAt` assignment | **REAL, minor** | §4E: seal is the last change before the single save; the choice drives the echo assignment; the test must seed `echoAt` the real way or it passes against the bug |
| Flash-1 / Pro-3 | App Intents: `openAppWhenRun` vs `supportedModes` across iOS 17 / Xcode 26.6 / Xcode 27 is a catch-22 | **PARTLY** — the recipe was missing, but all three technical claims were wrong | §4F: declare both witnesses; `supportedModes` exists since iOS 26.0 (so Xcode 26.6 has it) and no deprecation warns at a 17.0 target; no `#if compiler` |
| Flash-5 | Python policy tests never wired into CI | **REAL, minor** | §4B: exact CI step; a bare `python3 -m unittest` finds 0 tests here and exits 0 on Python < 3.12 |
| Flash-7 | Unclear how seal is chosen in capture review and when permission is asked | **REAL, minor** | §4E: modal `SealSheet`; authorisation inside `onSeal`; save stays synchronous |
| Flash-8 | "A defined order" with a pending deep link never says which wins | **REAL, minor** | §4F: newest request wins; the two are never both live |
| Flash-6 | Standing flags written before the save | **PARTLY, nit** (no observable privacy harm) | §4C: move the writes after the save; never reset them |
| Flash-9 | Name the existing dequeue API | **REAL, nit** | §4C: `DeliveryPreferences.resolvePendingCancel` |
| Pro-2 | Make capture save async and await `notifications.sync` | **WRONG** | Not taken. The gallery observer already syncs a new sealed capsule (`sealSignature`), reconcile retries a `nil` `serverJobSyncedAt`, and a second awaited sync would race the observer — the overlap §4D removes |

### Round 2 — same reviewers, on the revised plan, 2026-10-07

- **Gemini 3.8 Flash: APPROVE**, no findings.
- **Gemini 3.1 Pro: APPROVE WITH CHANGES**, one finding — the Home Screen quick action "handled
  through the existing `SoundpostAppDelegate`" would never fire: the app uses the SwiftUI scene
  lifecycle, which delivers shortcut items to the scene delegate only. **Verified REAL** against
  `SoundpostApp.swift:6`, the generated scene manifest (`project.pbxproj:291`) and the iOS 27 SDK,
  which deprecates the app-delegate method in favour of `windowScene(_:performActionFor:)` and
  `UIScene.ConnectionOptions.shortcutItem` (`UIApplication.h:453, 626`). §4F now specifies a scene
  delegate supplied through `configurationForConnecting`, covering cold and warm launch.

### Round 3 — confirmation, 2026-10-07

- **Gemini 3.1 Pro: APPROVE WITH CHANGES**, one blocker claimed: a custom scene `delegateClass`
  would eject SwiftUI from the scene lifecycle and launch to a black screen; drop the quick action.
  **Not accepted as stated:** supplying a scene delegate through `configurationForConnecting` is the
  documented SwiftUI quick-action pattern (Apple Developer Forums 656997, and the common tutorials),
  under which `WindowGroup` keeps rendering. The risk is real if the delegate creates its own
  window, so §4F now forbids that and requires a simulator launch check on the first S5 commit,
  with the drop already planned if it regresses. The claim and the evidence went back to the
  reviewer (round 4).
- **Gemini 3.8 Flash:** no output — headless `agy` denied its read of the SDK headers outside the
  workspace; re-run with the SDK directory added (round 4).

### Round 4 — final confirmation, 2026-10-07

- **Gemini 3.8 Flash: APPROVE**, no findings; it judged the round-3 dispute resolved in the plan's
  favour.
- **Gemini 3.1 Pro: APPROVE WITH CHANGES.** On the dispute: "the plan's author is right" — a
  supplied `UIWindowSceneDelegate` that does not create a window leaves SwiftUI creating the
  hosting window for `WindowGroup` and forwarding scene callbacks. Two clarifications, both applied
  verbatim in §4F: say that `configurationForConnecting` is new to `SoundpostAppDelegate`, and call
  `completionHandler(true)` in the warm-launch path. (Pro's headless runs twice aborted trying to
  run shell commands; the final round was given the §4F text, the two source files and the SDK
  lines inline instead.)

**Outcome:** both reviewers approve; no open findings.

---

## 13. Build record

### S0 — delivery witness (Jason's part runs in parallel; agent part landed with S1)

**Queries** (project `gkjwsxotmwrgqsvfijzs`, read-only; the user key is a bearer secret, so
only an 8-character md5 prefix is ever printed):

```sql
-- 1. Tombstones first: a tombstoned key makes registration fail for a reason that is not code.
select left(md5(user_key), 8) as key_hash, created_at from public.delivery_optouts order by created_at;
-- 2. Device tokens by environment (the witness expects a `production` row).
select environment, count(*), max(updated_at) from public.device_tokens group by environment;
-- 3. Jobs (the witness expects Asia/Tokyo, 09:00 on the sealed day, `pending`, then `sent`).
select left(md5(user_key), 8) as key_hash, capsule_id, kind, wall_clock, time_zone, status,
       attempts, last_error, updated_at
from public.notification_jobs order by created_at;
```

**Before the witness, 2026-10-07 15:00 JST:**

| table | rows | detail |
|---|---|---|
| `delivery_optouts` | **2** (the plan expected 1) | `b423c1b2` 2026-08-18 03:15 UTC; `7f251443` **2026-09-26 15:24 UTC** — six minutes after build 20's resubmission (15:18 UTC) |
| `device_tokens` | 0 | none in either environment |
| `notification_jobs` | 1 | `525b7989`, seal, 2027-09-15 09:00 America/Los_Angeles, `pending` |

- The job is the first evidence that a shipped build has written to the server — so
  `DeliveryIdentity` does work in Production since 2026-08-28. No token sits beside it. That
  is what declining notifications produces: `SoundpostAppDelegate` registers for APNs only
  when notifications are authorised, while `SealDeliveryService.reconcile` upserts a far seal
  regardless. The poller defers such a job without burning attempts (`mark_job_deferred`), so
  it is benign. A Los Angeles time zone on a sandbox-era date reads as App Review's device.
- The second tombstone's author is unknown. Asked Jason whether he pressed "Delete my cloud
  data" on js then; if js's key is tombstoned, the witness cannot pass and lifting the
  tombstone is a production write that is his call.
- Steps sent to Jason in Chinese: seal on **2026-10-09** (the day after tomorrow, 09:00
  JST), do not open Soundpost from 2026-10-08 09:00 until the push arrives, do not tap the
  push until `status = 'sent'` has been read (opening the app cancels the job), then tap it
  from a killed app for the cold-launch deep link. Reinstalling 1.9.0 over the uninstalled
  dev build also exercises "audio comes back from iCloud" (M9 §8).
- Stale comments fixed: `SupabaseDeliveryBackend.swift` (`functionsURL`) and
  `SoundpostApp.swift` (`registrar`) no longer say delivery is inert in production.

**Rows, 2026-10-07** (same read-only queries, 18:00 JST):

| table | row | when (JST) |
|---|---|---|
| `device_tokens` | `367e950d`, **`production`** | 16:54 |
| `notification_jobs` | `367e950d`, seal, **2028-06-09 09:00 Asia/Shanghai**, `pending` | 16:58 |

The first production token and the first job beside it, under a key that is not tombstoned —
an App Store build registered for APNs and handed a far seal to the server. **This is the S0
row evidence that gates uploading a build containing S4.** It is not yet the witness: that
seal is in 2028, so no push can be seen arriving from it. The phone's zone is Asia/Shanghai, so
a seal to 2026-10-09 fires at 09:00 Shanghai (10:00 JST), and "do not open from 09:00 the day
before" means 09:00 Shanghai on 10-08. Asked Jason to seal one more capsule to 10-09.

### S1 — release tooling refuses the wrong app, version, cancel, tree and an unsymbolicated upload

**What changed**

- `scripts/asc_policy.py` (stdlib only): `assert_app_identity`, `pick_version`,
  `releasable`, `may_cancel`, `submit_plan`, `build_number_is_new`, `screenshot_swap`. Each
  returns the decision or raises `Refusal`; `asc.py`'s `main()` turns that into a non-zero
  exit.
- `scripts/asc.py`: every write checks the app through the policy; `release` asks
  `releasable(versions, MARKETING_VERSION)`; `cancel` and `submit` keep a rejected
  (`UNRESOLVED_ISSUES`) submission unless `--force-cancel`, and print the thread-keeping path
  (attach → reply in the thread → Update Review → Resubmit); versions are fetched with
  `limit: 200` or `filter[versionString]` and picked by name; review submissions with
  `limit: 200` (20 unordered could hide a rejected one from the guard); screenshots upload
  and verify the new set before deleting the old; new read-only `check-build-number <n>`.
- `scripts/release-preflight.sh` (new) and `build-upload-asc.sh`: `PROJECT_DIR` derived from
  the script; preflight = one `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, no `* 2.*` /
  `* 2` copies, keychain not locked + a one-second `codesign` probe, and for an upload also a
  clean tree (untracked files included), a build number above App Store Connect's newest and
  a usable `SENTRY_AUTH_TOKEN`; an upload refuses an archive with no dSYMs or a failed Sentry
  upload; `git tag v<version>-b<build>` after a successful upload. One override:
  `RELEASE_PREFLIGHT_OVERRIDE=yes`, which lists what it skipped.
- CI: asserts `xcodebuild -version` is `Xcode 26.6`; "Release-tooling policy tests" runs
  `unittest discover` into `build/py-tests.log` and fails without `Ran N tests`, N ≥ 1;
  after the test step, fails unless `Test run with N tests` is present with N ≥ `MIN_TESTS`
  (637, raised from the plan's 634 by S1's three new tests).
- `TestSupport.freshStore` clears `SoundRejection`, and its list of cleared models is held
  equal to the shipping schema; `VocabularyPinTests` pins the 93 allowed identifiers.

**Deviations from §4B, and why**

- The preflight is its own script rather than inline in `build-upload-asc.sh`, so a release
  can see where it stands without starting a twenty-minute archive. A local `archive` runs
  only the iCloud-copy and signing checks.
- The tag is created locally and the push is printed, not run: pushing is outward-facing,
  and the person releasing pushes it.
- `cancel` refuses a rejected submission too, not only `submit`/`resubmit`.

**Review** (a three-lens adversarial pass — `asc.py`/policy against the ASC API, the shell
scripts under bash 3.2, CI and test vacuity — with every finding sent to an independent
verifier told to refute it). No blocker; seven confirmed, all minor, all fixed:

| Finding | Fix |
|---|---|
| The screenshot-order test only checked that `screenshot_swap` was *called*; deleting `old_ids` first passed | the test now requires the only pre-upload delete loop to iterate `delete_before` and the only post-upload one `delete_after` (P8b, P8c) |
| The refusal test accepted `sys.exit(0)` / `sys.exit()` in the handler | it now requires exactly one `sys.exit(str(<the refusal>))` inside the `Refusal` handler (P11, P11b) |
| `check-build-number` compared against whatever app `APP_ID` named | it checks the app first (P12) |
| The clean-tree check read a failing `git status` as clean | fails closed on git's exit status and on an unresolvable HEAD (R4) |
| The iCloud scan matched only ` 2`; the next copy is ` 3` | one regex for any copy number (R5); no tracked file matches it |
| The tag went on whatever HEAD was after a 20-minute archive; a failed `git tag` reported a finished upload as failed | the commit is recorded after the preflight, an upload refuses if HEAD moved or the tree got dirty during the archive, the tag names the recorded commit, and tagging only warns |
| The floor step's count assignment exited silently under `bash -e` before its own message | `|| true` inside the substitution |
| `TestSupportTests` named three entities and could not fail for a fourth | `clearedModels` is held equal to `productionSchema` (S1b) |

**Controls** (snapshot with `cp`, restored and `cmp`-checked after each):

| # | Mutation | Failed |
|---|---|---|
| P1 | `UNRESOLVED_ISSUES` back into `asc_policy.CANCELABLE` | `a_rejected_submission_is_kept_without_force`, `the_rejected_state_is_not_in_the_cancel_set` |
| P2 | `asc.py` grows its own `CANCELABLE` holding `UNRESOLVED_ISSUES` | `no_cancel_set_in_asc_py_holds_the_rejected_state` |
| P3 | bundle check dropped from `req()` | `every_write_checks_the_app_first` |
| P4 | `releasable` takes `pending[0]` | `never_releases_a_different_approved_version`, `picks_the_projects_version_even_when_it_is_not_first` |
| P5 | `cmd_release` picks by state itself | `release_asks_releasable` |
| P6 | `cmd_submit` skips `submit_plan` | `submit_asks_submit_plan_before_cancelling` |
| P7 | `may_cancel` lets `UNRESOLVED_ISSUES` through without force | `a_rejected_submission_is_kept_without_force` |
| P8 | `screenshot_swap` deletes everything first | `five_over_five_uploads_before_deleting_anything`, `only_the_overflow_goes_first` |
| P9 | `ios_versions` back to `limit: 10` | `versions_are_picked_by_name` |
| P10 | build numbers compared as strings | `numbers_compare_as_numbers` |
| C1–C3 | CI Python step run as committed / test file renamed / deleted | passes / **red** (`Ran 0 tests`) / **red** |
| C4–C7 | CI floor step: 12 tests / marker without a count / the real 636 / `MIN_TESTS=0` with 12 | **red** / **red** / passes / passes (what the floor exists to catch) |
| S1 | `freshStore` stops deleting `SoundRejection` | `freshStoreLeavesNoRowOfAnyEntity` |
| S2 | `"rain"` renamed `"rainfall"` in the vocabulary | `theAllowedIdentifiersAreExactlyThePinnedSet` (both directions) |
| R1 | `Soundpost/Probe 2.swift` present | preflight red; with the override, passes and lists it |
| R2 | `SENTRY_AUTH_TOKEN` unset / `"<abc>"` | preflight red, each with its own reason |
| R3 | dirty tree; build 20 against App Store Connect's 20 | preflight red on both (seen on the uncommitted S1 tree) |
| P8b | `cmd_screenshots` deletes `old_ids` before uploading | `screenshots_upload_before_deleting` |
| P8c | the `delete_after` loop moved above the upload | `screenshots_upload_before_deleting` |
| P11 / P11b | the `Refusal` handler exits `0` / calls `sys.exit()` bare | `a_refusal_exits_non_zero` (both) |
| P12 | `check-build-number` skips the app check | `build_number_check_is_wired` |
| S1b | `SoundRejection` dropped from `clearedModels` | `freshStoreClearsEveryEntityTheAppShips`, `freshStoreLeavesNoRowOfAnyEntity` |
| R4 | preflight run from a copy with no `.git` | red: "git status failed" |
| R5 | `Soundpost/Probe 3.swift` present | red, names the file |

Not exercised: the locked-keychain branch. Locking `login.keychain-db` to see it fail needs
Jason's password to undo; its detection lines are the ones the global notes measured on
2026-09-08.

Not exercised either: the "checkout changed during the archive" refusal, which needs a real
twenty-minute archive to race; it was read, not run.

**Bars:** 637 tests in 85 suites (clean Xcode 27 build, scratch DerivedData), 0 warnings,
i18n 100%, 39 Python policy tests.

The session also ran the disk to zero: the Mac had 123 MB free (85 GB in the Trash), every
build and even the review's own journal failed with `ENOSPC` until Jason emptied it.

### S2 — every user write lands, or changes nothing where the user can see it

**What changed**

- `CapsuleStore.commitSeal` / `commitUnseal` save as one write and, on a failed save, put
  every field back by hand from `Capsule.sealFields` (state, seal date, zone, echo,
  `serverJobSyncedAt`). `commitDelete` undoes the pending deletes of the capsule and its
  `SoundRejection` rows with `rollback()` — the right tool for a pending *delete*, and proved
  by test: a later unrelated save does not commit them.
- `CaptureViewModel.save(using:commit:)` takes its inserted row back out on a failed save;
  `hasRecordedHere` / `hasStanding` are written only after the save succeeds (moved, never
  reset). `CaptureView.save` no longer begins with `try? store.save()`.
- `CapsuleActions.delete` owns the delete order: queue the server cancel → delete + save →
  only then remove the audio file and call `cancelJob`; on failure resolve the queue entry.
- `CapsuleDetailView`: a failed seal, unseal or delete shows "Couldn't save your changes /
  Your capsule is unchanged. Please try again." (an existing EN/JA/ZH-Hans pair — no new
  strings) and stays; no "sealed — but reminders are off" after a failed seal.
- `SealDeliveryService.reconcile(capsules:in:now:)`: `drainPendingCancels` decides each
  queued id by a fresh fetch on the passed context — still there → resolve, no cancel; gone →
  cancel, resolve on success; fetch error → stay queued. This closes the M10-era kill window
  between the enqueue and the save.
- `DeliveryPreferences` gained the task-local `UserDefaults` suite `SoundAnalysisPreferences`
  already had (production reads `.standard` exactly as before): `reconcile` drains the whole
  queue, so tests on the shared defaults would cancel each other's ids.
- Bulk export (the drop-able item, kept): the bundle is built inside a
  `VideoExportWorkspace` named `SoundpostDataExports`, the uncompressed folder is removed once
  the zip exists, Settings cleans the workspace when the share sheet finishes, and the launch
  scavenge reclaims both containers.

**Deviation:** none in substance. The plan allowed "`CapsuleActions` (or methods on
`CapsuleStore` plus a small coordinator)"; seal and unseal are store methods, delete is the
coordinator, because only delete has side effects outside the store.

**Controls** (`scratchpad/mutate.py`: `cp` snapshot, apply, `-only-testing`, restore, `cmp`;
the working tree was compared before and after the whole run):

| # | Mutation | Failed |
|---|---|---|
| M1 | `commitSeal` skips the restore | `aFailedSealLeavesTheCapsuleCapturedInMemoryAndInTheStore` |
| M2 | `commitUnseal` skips the restore | `aFailedUnsealLeavesTheCapsuleSealedInMemoryAndInTheStore` |
| M3 | capture save keeps its row on failure | `aFailedCaptureSaveLeavesNoRowNoStandingAndATakeToRetry` |
| M4 | standing flags written before the save | `aFailedCaptureSaveLeavesNoRowNoStandingAndATakeToRetry` |
| M5 | `commitDelete` without `rollback()` | `aFailedDeleteKeepsTheCapsuleItsCorrectionsItsAudioAndItsPush` |
| M6 | audio file removed before the save | same |
| M7 | no `resolvePendingCancel` on failure | same |
| M8 | `cancelServerJob` called on failure | same |
| M9 | the drain's existence check disabled | `aQueuedCancelForACapsuleStillInTheStoreCancelsNothing` |
| M10 | the drain decides from the `capsules` array | that test and `aStaleSnapshotStillHoldingADeletedCapsuleDoesNotSaveItsJob` |
| M11 | seal's catch shows the alert but does not `return` | `aFailedSealOrUnsealTellsTheUserAndGoesNoFurther` |
| M12 | delete dismisses whatever happened | `aFailedDeleteDoesNotLeaveTheScreen` |
| M13 | `try? store.save()` back at the start of capture's save | `theCaptureRetryDoesNotBeginBySaving` |
| M14 | unseal's catch shows nothing | `aFailedSealOrUnsealTellsTheUserAndGoesNoFurther` |
| M15 | the cancel queued after the save | `aDeleteThatLandsRemovesTheFileAndAsksTheServerAfterwards` |
| M16 | the uncompressed folder left beside the zip | `exportLeavesOnlyTheZipAndTheScavengeReclaimsIt` |
| M17 | the export ignores the workspace it is given | same |
| M18 | the upsert loop without its existence check | `aStaleSnapshotDoesNotUpsertAJobForACapsuleTheStoreNoLongerHas` |
| M19 | the view's seal back to `store.seal` + `save()` | `aFailedSealOrUnsealTellsTheUserAndGoesNoFurther` |
| M20 | seal's catch also `dismiss()`es | same |
| M21 | the view's unseal back to `store.unseal` + `save()` | same |

**Review** (three lenses — the write paths under a real save failure, far-future delivery,
test strength — each finding sent to a verifier told to refute it). Three confirmed, all
minor, all fixed; two rejected:

| Finding | Fix |
|---|---|
| A delete landing during one of `reconcile`'s awaits (the cold-launch key lookup takes seconds) left the stale snapshot's far seal to be **upserted again after the drain had cancelled it** — a job nothing would ever cancel, pushing for a deleted capsule. Pre-existing since M10 | the upsert and cancel loops skip a capsule a fresh fetch no longer finds, checked synchronously right before the claim (M18) |
| The view guard read only the catch block, so reverting the view to `store.seal` + `save()` (no restore) passed every test | it requires `commitSeal(` / `commitUnseal(`, forbids a hand `save()`, and forbids `dismiss()` in the catch (M19–M21) |
| The export workspace was cleaned on the share sheet's first activity callback, which a cancelled sub-activity fires while the sheet stays up | cleaned in `.sheet(onDismiss:)` — and the video share, which had the same pattern since M13, likewise |

Rejected after verification: "the stale-snapshot test uses a draft capsule" (it tests exactly
what §4C asks of the drain; the sealed case is now M18's test) and "the failed-seal test
cannot see `serverJobSyncedAt`" (`restore` writes it back; the unseal test asserts it).

Left as is: a delete that races an upsert *already in flight* can still lose to it on the
server. Closing that needs the server to refuse an upsert for a cancelled id, which is a
schema change — M21 if it ever shows up.

**Bars:** 650 tests in 87 suites (clean Xcode 27 build), 0 warnings, i18n 100%; CI floor
raised to 650.

The view half (M11–M14) is a source-shape guard, `WriteFailureViewGuardTests`, in the
`ProOfferTests` manner: it fails when the stop-and-tell or the retry's pre-save changes, not
for every way a view could be wrong. There is still no UI-test target, by standing rule.

A probe on the macOS 27 SDK found `rollback()` restoring a mutated object's property there,
contrary to this repo's notes (`CapsuleStore.update`); the iOS behaviour those notes record
was not re-measured, and S2 restores by hand regardless.

### S3 — silent wrong answers become retryable or impossible

**What changed**

- **Analysis failure.** `SoundAnalysisClassifier`'s observer records `didFailWithError`, and
  the pure `SoundAnalysisClassifier.outcome(failure:labels:)` throws it, so
  `SoundprintService` returns `.skipped(.failed)` instead of an empty result stored as
  "nothing heard". Checked against the iOS 27 SDK first: `SNAnalyzer.h` says errors "flow
  downstream to the request observers"; `analyze()`'s `didReachEndOfFile` is only about
  `cancelAnalysis`.
- **Bounded retries.** `SoundprintRetryLedger` (device-local `UserDefaults`, a suite per
  test, keyed by `Capsule.id`, cap 3) counts every "could not listen on this device" result —
  `.skipped(.failed)` and `analyse` returning `nil` — but not `.notPermitted`, cancellation or
  a batch dropped for consent; it is cleared when the capsule is written. A capped capsule
  stays `nil` (never the empty marker) and is left out of the fetch with
  `soundprintRaw == nil && !excluded.contains($0.id)`, the plain predicate when nothing is
  excluded.
- **Reconcile.** `NotificationScheduler.reconcile` takes a ticket from `ReconcileTurnstile`
  (an actor-based FIFO lock held across the diff's awaits, so the work stays in the caller's
  task) and does nothing if a newer call took a ticket while it waited. The almanac's 64-slot
  baseline is untouched — the planner did not change.
- **Sentry (the first drop-able item, kept).** `CloudSyncMonitor` reports an unsurfaced sync
  error once per (domain, code, `CKError` code) per launch, as three integers through new
  `Diagnostics` / `SentryBootstrap` overloads; the domain is a fixed small number, never its
  string.

**Deviation — one try per capsule per run, with a circuit breaker.** §4D's drain stopped on
a batch that wrote nothing. That made a *mixed* batch re-fetch the same corrupt clip in every
following batch of one run, spending all three tries in a single launch. Now a capsule that
fails is left out of the rest of the run, and the drain goes on after a mixed batch — but a
batch in which *every* clip failed still stops the run, because that is what a device-wide
failure looks like (review finding below). So each broken clip is tried once per launch; the
plan's case is unchanged — the older capsule is labelled on launch `cap + 1`.

**Review** (three lenses: the reconcile turnstile, analysis + ledger + backfill, the Sentry
dedupe; each finding sent to a verifier told to refute it). Three confirmed, all minor, all
fixed; three rejected:

| Finding | Fix |
|---|---|
| The turnstile numbered calls in the order they *reached* it. `reconcile` is nonisolated, so it hops off the main actor first, and a stalled hop could arrive after a newer call — the older plan applied last, or the newer one skipped | `NotificationCoordinator.sync` numbers each call on the main actor before its first suspension and passes the number in; `isSuperseded` is "a higher number has been seen, or one at least this high was applied" (G1, G2) |
| A device-wide failure (a full disk failing every scratch write, a classifier that cannot start) no longer ended the run, so one run spent a try on **every** unanalysed capsule and three runs capped the whole library for good | a scratch write that fails is `couldNotStage` — about the device, not counted, and the run ends (B2); an all-failed batch is a circuit breaker (B1) |
| Nothing ever emptied the ledger, so a capped capsule stayed excluded after listening was switched off and on, contradicting the eraser's "picked up again if the user changes their mind" | `SoundprintEraser.eraseAll` empties it once the erase lands (B3) |

Rejected: "the overlap tests depend on fixed sleeps" (the ordering comes from the FIFO and
the held `add`, not from the waits); "the CloudKit code is the wrapper's, so partial failures
share a key" (true of `partialFailure`, and one report per kind per launch is the intent);
"the local log line is deduped too" (it is, and one line per kind is what the log needs).

**Controls** (all re-run against the final code)

| # | Mutation | Failed |
|---|---|---|
| R1 | the scheduler without the turnstile (the pre-M20 code) | `anOlderReconcileCannotPutBackWhatANewerOneRemoved`, `aReconcileOvertakenWhileWaitingIsSkipped`, `anOlderGenerationArrivingLastChangesNothing` |
| R2 | the turnstile actor kept, but `enter()` never waits | the first two |
| R3 | **actor-only**: the diff run inside an actor method (`await turnstile.run { await apply(desired) }`) | all three — actor reentrancy interleaves at the same `add` |
| R4 | an overtaken call still applies its plan | `aReconcileOvertakenWhileWaitingIsSkipped`, `anOlderGenerationArrivingLastChangesNothing` |
| G1 | tickets in arrival order again (generation ignored) | `anOlderGenerationArrivingLastChangesNothing` |
| G2 | the coordinator passes no generation | `eachSyncIsNumberedBeforeItCanSuspend` |
| A1 | `outcome` ignores the failure | `aFailureReportedByTheAnalyzerIsNotAnEmptyAnswer` |
| A2 | the observer drops the failure again | `theRealClassifierRecordsAndReportsTheObserversFailure` |
| A3 | capped capsules not excluded | `unreadableClipsCannotStarveOlderOnesAndStopAtTheCap` |
| A4 | no exclusion at all (the plan's control) | that test and `aBrokenClipIsTriedOncePerLaunchEvenAmongReadableOnes` |
| A5 | the empty marker written for an unreadable clip | the same two |
| A5b | the empty marker written for `.skipped(.failed)` | `aClassifierFailureIsCountedAndLeftNil`, `aDeviceWideFailureCostsOneBatchNotTheWholeLibrary` |
| A6 | failures counted before the consent check | `aBatchDroppedForConsentCountsNothing` |
| A7 | the ledger not cleared when a capsule is written | `aCapsuleThatIsFinallyReadForgetsItsFailures` |
| A8 | the drain stops on `written == 0` | **survives — expected**: with the circuit breaker an all-failed batch stops anyway, so the mutation is now equivalent |
| B1 | no circuit breaker | `aDeviceWideFailureCostsOneBatchNotTheWholeLibrary`, `unreadableClipsCannotStarveOlderOnesAndStopAtTheCap` |
| B2 | a failed scratch write counted against the clip | `aClipThatCannotBeStagedIsNotCountedAgainstIt` |
| B3 | the erase keeps the caps | `switchingListeningOffForgetsEveryCap` |
| B4 | no per-run exclusion | `aBrokenClipIsTriedOncePerLaunchEvenAmongReadableOnes` |
| D1 | every sync error event reported | `aRetryStormIsReportedOnce` |
| D2 | the `CKError` beneath not looked for | both report tests |
| D3 | the Cocoa domain not mapped | `theReportCarriesTheDomainAndTheCloudKitCodeBeneath` |

`ReconcileOverlapTests` was also run 20 times in a row (`-test-iterations 20`), green each
time: it waits on conditions with deadlines, never on a fixed sleep alone.

**Bars:** 667 tests in 90 suites (clean Xcode 27 build), 0 warnings, i18n 100%; the almanac's
64-slot baseline unchanged; CI floor raised to 667.

### S4 — seal at capture review, and one onboarding line

**Committed before S0 finished, as §5 allows. No build containing it is uploaded until S0's
rows are recorded.**

**What changed**

- `CaptureViewModel.ComesBack` — `.echo` (the default), `.sealed(until:)`, `.off`. A seal always
  carries its day; `chooseSeal(until:)` is called only from the seal sheet's Seal button;
  `reset()` returns to `.echo`. `echoEnabled` is now derived: turning the echo on replaces a
  seal, turning it off leaves a seal alone.
- In `fill`, `echoAt` is written only for `.echo`, and `store.seal` is the last change before
  the single save. The instant is decided **at Save** (`sealInstant(for:now:)`, review finding
  below).
- Capture review's section is now "When it comes back": the echo control and "Seal it until a
  day you choose", or "Sealed until <day>" with Remove and `SealSheet.promise(for:canPromise:)`
  — the sheet's own sentence, now a `static func` both screens share. A third `.sheet`
  presents `SealSheet(initialDate:)`; its `onSeal` sets the choice and requests notification
  authorisation. Neither it nor the save calls a sync: the gallery observer sees the new
  `sealSignature`.
- Onboarding page 3: "…You can change or turn this off anytime, or seal a capsule until a day
  you choose." Three new strings and the replaced onboarding key, all in EN/JA/ZH-Hans (JA
  封印, ZH 封存, as the app already says).
- The comments at `NotificationCoordinator.remindersWouldBeDelivered` and `CaptureView.echoPromise`
  now say "capture's echo never asks; capture's seal option asks when its date is confirmed,
  as the seal sheet does". `EchoPromiseTests` unchanged and green.

**Seen in the simulator** (Debug build, iPhone 17 Pro, iOS 26.5): onboarding page 3 shows the
new line; recorded a take; the review screen shows "When it comes back" with the echo row and
the seal button; the sheet opened from it; Seal asked for notification permission at that
moment; with permission denied the row switched to "…Notifications are off, so nothing will
alert you — it reappears here on its date…"; the saved capsule appeared sealed ("Opens Apr 7,
2027") and under Coming up. The test install was removed afterwards.

**Review** (two lenses: the model and data path, the views and copy; each finding sent to a
verifier told to refute it). Confirmed, minor, fixed:

| Finding | Fix |
|---|---|
| Sealing **until today** in capture: the picker hands over "a minute from now", but capture seals at Save, minutes later — `humaneInstant` keeps a time already past, so the seal is over at birth and the reminder the row promised is never scheduled. The M17 §S4 defect through the new door | the instant is decided at Save: a time no longer ahead becomes a minute from Save, which is what the detail screen's seal-until-today amounts to; `SealSheet(initialDate:)` also clamps a stale day to its own floor |
| The row-sentence test checked the authorisation rule and a source string, not which sentence the row shows — swapping `promise`'s branches stayed green | it reads each `LocalizedStringKey`'s catalog key and asserts the reminder sentence for `.notDetermined`/`.authorized` and the notifications-off one for `.denied` |

Rejected: "no test catches the seal moved before the echo line on its own". True, and by
design — see C1b.

**Controls**

| # | Mutation | Failed |
|---|---|---|
| C1 | `store.seal` moved before the echo line **and** the echo line ignoring the choice | `aCaptureSavedSealedIsSealedAtNineAndNeverEchoes`, `unsealingASealedCaptureLeavesNoEchoBehind` |
| C1b | the reorder alone | **survives — expected**: the three-way choice already writes `nil` for a seal, so the order and the choice each protect on their own |
| C2 | `reset()` keeps the seal | `theChoiceIsClearedByResetAndNeverExistsWithoutADay` |
| C3 | Remove on the seal row goes back to the echo | `turningTheEchoOffLeavesASealAloneAndOnReplacesIt` |
| C4 | turning the echo off clears a seal | same |
| C5 | the row uses `remindersWouldBeDelivered` | `theSealRowPromisesExactlyWhenTheSealSheetDoes` |
| C6 | the seal chosen when the sheet opens | `permissionIsAskedOnSealAndNothingInCaptureSyncs` |
| C7 | capture runs its own sync after Seal | same |
| C8 | permission asked at Save instead | same |
| C9 | the seal choice ignored by the save | four tests |
| C10 | no floor at Save | `aCaptureSealedUntilTodayIsStillAheadWhenItIsSaved` |
| C11 | `promise`'s branches swapped | `theSealRowPromisesExactlyWhenTheSealSheetDoes` |

Note for Jason (§4E): the rating prompt fires after a reveal, so more seals mean more eligible
prompts — still once per version.

**Bars:** 675 tests in 91 suites (clean Xcode 27 build), 0 warnings, i18n 100% across 349
strings; CI floor raised to 675.

### S5 — more ways into capture, through one tested route

**What changed**

- `OpenCaptureIntent` ("New capsule"): `static let openAppWhenRun: Bool = true` **and**
  `@available(iOS 26.0, *) static let supportedModes: IntentModes = .foreground`, no `#if`;
  `perform()` only sets the capture request. `SoundpostShortcuts` offers three phrases, each
  with `\(.applicationName)`, translated in a new `Soundpost/AppShortcuts.xcstrings` (the
  localization gate globs it — now 3 catalogs). No entity, no Spotlight items for capsules.
- A static `UIApplicationShortcutItems` "New capsule" entry in `Soundpost-Info.plist`; its title
  is localized through `InfoPlist.xcstrings` keyed by the title (the system looks a shortcut
  title up by its own text). Checked in the built bundle: `ja.lproj/InfoPlist.strings` holds
  "New capsule" = "新しいカプセル", zh-Hans "新建胶囊"; `AppShortcuts.strings` holds the phrases.
- `SoundpostAppDelegate.application(_:configurationForConnecting:options:)` (new) returns a
  default `UISceneConfiguration` whose `delegateClass` is `SoundpostSceneDelegate`, which
  implements only `scene(_:willConnectTo:options:)` (cold: `connectionOptions.shortcutItem`) and
  `windowScene(_:performActionFor:completionHandler:)` (warm: answers `completionHandler`). It
  creates no window.
- `CaptureRequests` — one hook, installed in `SoundpostApp.init` — sets
  `NotificationCoordinator.pendingCaptureRequest`. On that one main-actor owner: `requestCapture()`
  drops a waiting notification link, `openFromNotification(_:)` (now what `didReceive` calls)
  drops a waiting capture request — the newest wins, no clock. Opening capture by any door
  (`.onChange(of: showingCapture)`) also drops a waiting link.
- `CaptureLaunchRoute.decide(requested:on:)` — present / alreadyOpen / wait / none: wait through
  unfinished onboarding and until the gallery exists, never cover a reveal or Settings, never
  stack on capture. `ContentView` drains it after every `refreshAndSync` (the cold-launch case),
  on change, and when Settings or a reveal closes.

**Compiled metadata** (`Metadata.appintents/extract.actionsdata` of the Debug build):
`OpenCaptureIntent` has `openAppWhenRun: true`, `supportedModes: 2` (foreground), title key "New
capsule", three phrase templates and short title "New capsule". Clean Xcode 27 build: no
deprecation or other warning from either declaration.

**Seen in the simulator** (Debug, iPhone 17 Pro, iOS 26.5) — the plan's launch check for the
commit that adds the scene delegate:

1. Launches normally (no black screen) to onboarding.
2. Home Screen long-press shows "New capsule". Tapped **with onboarding unfinished**: the app
   stayed on onboarding. After Skip, capture opened — **idle**, record button untouched.
3. Recorded and saved a capsule, killed the app, sent a push carrying its `capsule_id`
   (`simctl push`), tapped the banner: the app cold-launched straight to that capsule. The
   `UNUserNotificationCenter` delegate is unaffected by the scene delegate.
4. With the app backgrounded on a detail screen, the quick action opened capture (idle) over it.

**Not run here — left for Jason's device check:** the intent through Shortcuts on an iOS 17–25
runtime. A `Soundpost-iOS18` simulator (iOS 18.5) was created and the build installed, but the
simulator tool needs Jason's one-time permission for a new device. The compiled
`openAppWhenRun: true` above is what that runtime reads.

**Controls**

| # | Mutation | Failed |
|---|---|---|
| Q1 | the route ignores onboarding | `theRouteDecidesFromTheScreen` |
| Q2 | the route ignores whether the gallery exists | same |
| Q3 | `requestCapture` keeps a waiting link | `aCaptureRequestDropsAWaitingLink` |
| Q4 | `openFromNotification` keeps a waiting request | `aNotificationTapDropsAWaitingCaptureRequest` |
| Q5 | `openAppWhenRun` removed | `theIntentOpensTheAppOnEverySupportedSystemAndNeverRecords` |
| Q6 | the scene delegate creates a `UIWindow` | `theSceneDelegateMakesNoWindowAndAnswersTheSystem` |
| Q7 | the warm path never calls `completionHandler` | same |
| Q8 | the quick-action type drifts from Info.plist | `theQuickActionInInfoPlistIsTheOneTheAppHandles` |
| Q9 | `refreshAndSync` no longer drains the request | `theGalleryDrainsAfterItExistsAndCaptureDropsAWaitingLink` |
| Q10 | opening capture keeps a waiting link | same |
| Q11 | `didReceive` sets the link directly again | `aNotificationTapGoesThroughTheNewestWinsRule` |

| Q12 | the cold-launch drain moved back behind the sync | `theGalleryDrainsAfterItExistsAndCaptureDropsAWaitingLink` |
| Q13 | opening a capsule keeps a waiting request | same |
| Q14 | the rating prompt asked over a capture a closing reveal released | same |
| Q15 | a capture opened by "+" keeps the request | same |

The door checks are source-shape guards (no UI-test target, by standing rule); the route and
the newest-wins rule are behaviour tests.

**Review** (two lenses: routing and lifecycle, App Intents and Info.plist; each finding sent to
a verifier told to refute it). Confirmed and fixed:

| Finding | Fix |
|---|---|
| **major** — a cold-launch request is set before the gallery's first body, so only the drain at the *end* of `refreshAndSync` saw it: behind CloudKit's delivery-key lookup and the delivery server, seconds outdoors. Meanwhile the gallery was live, and nothing the person did cancelled the request — capture could slide up over a capsule they had opened, or after a capture they made themselves | drained at the top of `refreshAndSync`, before anything awaits (the trailing drain stays); the person's own navigation supersedes a waiting request as it does a link — opening a capsule, opening Settings, and opening capture by any door consume it (Q12–Q13, Q15) |
| Closing a reveal with a request waiting asked for a rating and opened capture at once | the request is drained first, and the rating prompt is skipped (and left unspent) when capture opened (Q14) |

Rejected: "the route cannot see the detail screen's own sheets" — true of the route, but SwiftUI
refuses to present a second sheet from the root while a child sheet is up, the request is then
consumed without effect, and the person is where they chose to be.

Re-checked in the simulator after the fixes: with onboarding complete and the app killed, the
quick action opened capture (idle) directly.

**Bars:** 684 tests in 92 suites (clean Xcode 27 build), 0 warnings, i18n 100% across 3 catalogs;
Release debug-only gate green; CI floor raised to 684.

### S6 — the release: 1.10.0, build 22

**Build 21** (commit `7e67776`, tag `v1.10.0-b21`) was archived with Xcode 27.0 (27A266a),
uploaded at 2026-10-08 01:01 JST (dSYMs to Sentry: 3 files), processed `VALID`, and attached to
a new 1.10.0 version record (`releaseType MANUAL` — inherited, read back from the API;
description and What's New pushed in three languages; keywords and screenshots inherited). It
was **not submitted**: the whole-milestone review below ran in parallel and found one defect
worth a new build.

**Pre-upload review** — seven cross-cutting lenses over `a12a48b..HEAD` (interactions between
steps, data and sync, delivery, App Review, copy and localization, tests and CI, concurrency),
each finding sent to two verifiers told to refute it (one tracing the code path, one judging
the harm), then a completeness critic that added three focused lenses (presentation state,
minimum-OS runtime behaviour, state that outlives a device). 31 agents. Outcome:

| Finding | Verdict | Done |
|---|---|---|
| A capture request (Siri, Shortcuts, Action Button, quick action) while a capsule's own sheet, alert or dialog is up: the route could not see it and said `.present`. **On iOS 17–25** SwiftUI refused the presentation but left `showingCapture` true, so "+" stopped working until the app was force-quit; on iOS 26 SwiftUI dismissed the person's sheet (unsaved edits too). Read from the SwiftUI binaries of the iOS 18.5 and 26.5 simulator runtimes. New in S5 | contested → **fixed** (the iOS 18 path was confirmed) | `CaptureLaunchRoute.declined`: when UIKit shows a presentation the gallery's flags do not account for, the request is consumed and nothing is toggled (F1–F3). Simulator, iOS 26.5: seal sheet open on a detail screen + quick action → the sheet stays; after closing it "+" opens capture; from the plain gallery the quick action still opens capture idle |
| Sealing **until today** from the *detail screen* could also store a time already past (it writes after awaiting the permission prompt) — the same defect S4's review fixed for capture. Pre-existing | confirmed, minor → **fixed** | `CapsuleStore.sealInstant(for:in:now:)`, one rule for both doors, decided at the write (F4–F5) |
| The analysis retry ledger lived in `UserDefaults`, which travels with a backup and with Quick Start: a new phone inherited the old one's caps. New in S3 | confirmed, minor → **fixed** | a JSON file in Application Support marked `isExcludedFromBackup` after every write (F6) |
| "Export your data" bundles left in `tmp` by 1.9.0 and earlier (an uncompressed copy of every clip) were never reclaimed. Pre-existing | confirmed, minor → **fixed** | a launch scavenge of directories directly in `tmp` named `Soundpost-Export-*` (F7–F8) |
| The far-seal "synced" stamp is persisted before the server confirms. Pre-existing since M10 | confirmed, minor, not blocking | **M21** (§11); the S4 comment that promised otherwise corrected |
| Build 21 is already uploaded, so any fix needs build 22 | process | build 22 |

Refuted: "the listing's 'or any time after' is untrue for opened capsules" (×2 — the sentence
is about a captured capsule, which can be sealed any time), "the quick action may not reach the
scene delegate for users updating from 1.9.0" (SwiftUI supplies the class each connection; read
from the binaries), "the Siri phrase 'Record a sound' over-promises" (it opens capture, ready to
record — §8 D2).

**Controls**

| # | Mutation | Failed |
|---|---|---|
| F1 | the route ignores an unowned presentation | `theRouteDecidesFromTheScreen` |
| F2 | the gallery passes `false` instead of asking UIKit | `theGalleryAsksUIKitAndADeclinedRequestOpensNothing` |
| F3 | a declined request still sets `showingCapture` | same |
| F4 | no floor in `sealInstant` | `theSealInstantIsDecidedAtTheWrite`, `aCaptureSealedUntilTodayIsStillAheadWhenItIsSaved` |
| F5 | the detail screen writes the picked date | `theDetailScreenSealsAtTheInstantOfTheWrite` |
| F6 | the ledger file not excluded from backup | `theLedgerStaysOnTheDeviceThatWroteIt` |
| F6b | marked only on the first write, so a rewrite puts it back into backups | same — after the fixes' own review (below) made the test read from disk |
| F7 | the scavenge removes a matching *file* too | `theLaunchScavengeRemovesOnlyOldExportBundles` |
| F8 | the scavenge removes nothing | same |

**Review of these fixes** (three lenses — the route and its UIKit probe on every OS version,
the seal instant, the ledger and the scavenge — each finding sent to two verifiers). The probe
and the seal-instant lenses found nothing. One confirmed, minor, fixed: the backup-exclusion
test re-read `ledger.fileURL`, whose resource values a `URL` caches until the run loop turns, so
its "still excluded after a rewrite" check could not fail; it now reads through a fresh URL, and
F6b shows it failing.

**Bars:** 689 tests in 92 suites (clean Xcode 27 build), 0 warnings, i18n 100% across 3
catalogs, store-metadata gate green, 39 Python policy tests; CI floor raised to 689.

**Build 22** (commit `28e4466`, tag `v1.10.0-b22`): archived with Xcode 27.0 (27A266a), uploaded
2026-10-08 02:53 JST (dSYMs to Sentry), processed `VALID`, attached to 1.10.0 in place of build
21. CI green on `28e4466` (689 executed, floor 689); every M20 commit has its own green run
(S5's, cancelled by the next push, was re-run). **Submitted for review 2026-10-08 ~03:10 JST**
through `asc.py submit` — submission `8457f113-a58d-473f-a0cd-5c1b243b3a4d`, version state
`READY_FOR_REVIEW`, `releaseType MANUAL`. Nothing goes public until Jason says so
(`asc.py release`, which only acts on an approved 1.10.0).

**Still open for Jason** (§0, §8): the delivery witness's push arrival (`status = 'sent'`); the
S5 device check from a killed app, and the intent through Shortcuts on an iOS 17–25 runtime (a
`Soundpost-iOS18` iOS 18.5 simulator was created for it; the simulator tool needs his one-time
permission to drive a new device); D5–D9; the release itself.
