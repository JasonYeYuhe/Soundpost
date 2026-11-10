# M21 — "Delivered on the day"

> Status: **PLAN, approved** (2026-11-08) — three review rounds by Gemini 3.8 Flash via `agy`,
> every finding checked against the code (§12); Jason decided §8 D2. Grounded at `7b3e1d5` from three sources: the
> M20 pre-upload review's open findings (`M20-DEVPLAN.md` §11, §13 S6), a read-only pass over
> Sentry, App Store Connect and the delivery database after 1.10.0 went live, and a line-level
> code pass over every M21 candidate. Every claim below names its file and line; re-verify
> before you change anything. 1.10.0 (build 22) **live since 2026-10-08 05:44 UTC**.

---

## 0. Goal & success statement

**What the data says (facts, 2026-11-08).** Since 1.10.0 went live: 7 sessions from 5 installs
(Sentry), 0 crashes, 0 hangs, 0 ratings, 0 reviews; 19 lifetime first-time downloads, 10 of them
in October (App Store Sales and Trends). Not one of the M20 failure notices ("Seal failed…",
"Delete save failed…") has fired — at this volume that is weak evidence, not proof. The delivery
server is alive: its per-minute poller claimed the one job that has come due and recorded
`no_tokens` (that user never registered an APNs token). **No push has yet been sent to a phone
that has a token.**

**What the code says.** The far-seal promise — "Soundpost will hide this capsule and notify you
on <day>" — breaks at its last edge. A sync plans local notifications *first* and reconciles
server jobs *second* (`NotificationCoordinator.swift:152`, then `:198`). When a far seal enters
its last 24 hours (`SealDeliveryRouter.localHorizon`, `SealDeliveryService.swift:15`), the plan still excludes it because
the server owns it (`NotificationPlanner.swift:59`, `serverJobSyncedAt != nil`), and then the
reconcile cancels the server job and clears the stamp to hand the seal back to the device
(`SealDeliveryService.swift:103–116`). Nothing re-plans in that sync, and `sealSignature`
(`UpcomingResurfaces.swift:46–55`) does not hash the stamp, so nothing triggers one. **If the app
is opened once in the seal's last day and not again before it is due, neither the push nor the
local reminder fires.** For someone who opens the app about once a day, the last open before the
due time usually *is* in that last day. M20's S0 instructions told Jason not to open the app in
that window — a workaround for this defect, not a property of the design.

Three more promise-level defects sit next to it: the "synced" stamp is persisted (and mirrored
to every device) before the server has confirmed the job; a phone set up as new can analyse the
library of someone who said no to listening before their answer arrives from iCloud; and the
edit sheet's "Remind me of this later" never says when notifications are off.

**M21 makes the seal deliver on its day, holds consent at the launch edge, and closes the honesty
gaps M20's review left — then hands Jason a decision on growth.** Usage, not stability, is the
real constraint; the levers that would most change it (a Home Screen widget, a Control Center
control) need a new target, which M20 §1 forbade and which only Jason can allow (§8 D2). M21
does not wait for that decision.

**Success** — all of these hold for the 1.11.0 build:

- A far seal whose last day is entered with the app open, and which is not opened again, still
  fires: a test drives the exact sequence (stamp set → sync inside the horizon → no later sync)
  and asserts a pending local request for it after that one sync; the same test fails on today's
  code.
- `serverJobSyncedAt` is written only after the server has answered, and only for a capsule a
  fresh fetch still holds with the same `sealUntil` and zone; a backend that never returns leaves
  the field `nil` and the local reminder scheduled.
- A read-only query shows `status = 'sent'` for a job whose user has a token, and Jason saw the
  push (S0).
- The launch order (consent → re-sync → standing → remediation → backfill) lives in one tested
  type; a throwing consent read means no remediation and no backfill, and the test fails if any
  two steps are swapped.
- A phone that completes onboarding *after* this version is installed gains listening standing
  only by recording or by its consent answer — never from `hasCompletedOnboarding` alone.
- Every place that promises a reminder uses one of the two documented rules, and the edit sheet
  says so when notifications are off.
- Standing bars at every commit (§1.7).

**Not success:** a green `SealDeliveryTests` that never runs a sync inside the 24-hour horizon
(none does today); a delivery "confirmed" by a notification on the lock screen (the local
reminder and the push look identical — only `status = 'sent'` proves the server sent it); a
"LaunchSequence" whose test only checks that each step was called, not the order.

---

## 1. Non-negotiables (carried from M20 §1, unchanged unless noted)

1. **Calm, honest, literal copy** in EN · JA · ZH-Hans. Every sentence is literally true of the
   build for every state it can be shown in.
2. **No counters, streaks, nags or engagement prompts. No new notification kind.**
3. **Free stays free; Pro stays hidden.** `ProOffer.isOnSaleInThisBuild` stays `false`
   (`ProGate.swift:136`); no Pro door, string or StoreKit purchase is reachable by anyone.
4. **No new CloudKit field or entity; no Console deploy.**
5. **No new target, App Group, entitlement or deployment-target raise** (iOS 17.0) — *in M21*.
   §8 D2 asks Jason whether M22 may lift this for a widget/control target.
6. **Delete no audio** except the user's own explicit delete.
7. **Standing bars at every commit:** warning-free on CI's Xcode (26.6) and on a clean local
   Xcode 27 build (`xcodebuild clean test` in place — `soundpost-clean-gate-in-place` memory;
   `check-warnings.sh` passes vacuously on an incremental build); all tests green with the
   executed **count** confirmed (CI floor `MIN_TESTS`, now 689 — raise it with every step); i18n
   100%; zero new dependencies; CI green on the pushed commit. Every new test is seen to fail
   against a deliberately broken implementation (`cp` snapshot, never `git checkout`;
   `-collect-test-diagnostics never`); record mutation → failing test in §13.
8. **Builds go through the shared package checkout** (`CLAUDE.md`, `scripts/lib/build_cache.sh`):
   one derived-data root for this checkout, reused across steps; never under `~/Documents`.
9. **Production data is read-only for the agent.** The Supabase project `gkjwsxotmwrgqsvfijzs`
   is shared with other apps; a migration or function deploy there is Jason's word (§8 D3).

---

## 2. Scope

| Step | What | Size | Human step |
|---|---|---|---|
| **S0** | Witness one APNs send to a phone with a token (`status = 'sent'`) | S | **Jason, day 1, in parallel** |
| **S1** | The seal delivers on its day: re-plan after a delivery change; stamp only after the server answers | M | none |
| **S2** | `LaunchSequence`: the privacy-critical launch order in one tested type (order-only refactor) | M | none |
| **S3** | Listening standing is earned, not inherited from onboarding | S | §8 D4 (default assumed) |
| **S4** | Honesty and noise: edit-sheet reminder notice, expected network errors not reported, dormant store retry; CI package cache | S | none |
| **S5** | Delivery server hygiene: `no_tokens` jobs end; old rows expire (SQL only) | S | **Jason applies the migration** (§8 D3) |
| **S6** | 1.11.0 release: notes, listing where literally true, gates, submission | S | Jason says release |

**Drop order if tight:** S5's CI step → S4's CI package cache → S4's store retry → S5 → S4. Never drop S1 (the headline
defect) or S2/S3 (privacy).

---

## 3. Current state (grounded 2026-11-08 at `7b3e1d5` — re-verify)

- **Release:** 1.10.0 build 22 live; `MARKETING_VERSION 1.10.0`, `CURRENT_PROJECT_VERSION 22`.
  689 tests in 92 suites, CI floor 689, 0 warnings, i18n 100% (Localizable, InfoPlist,
  AppShortcuts catalogs).
- **Sync order** (`NotificationCoordinator.sync`, `:148–199`): number the call → plan locally →
  build copy → `scheduler.reconcile(…, generation:)` → `sealDelivery?.reconcile(…)`. The
  turnstile (`ReconcileTurnstile`, M20 S3) serialises scheduler reconciles and skips a superseded
  generation.
- **`serverJobSyncedAt` lifecycle:** set `now` *before* `await backend.upsertJob`
  (`SealDeliveryService.swift:90`), cleared on a thrown error (`:95`); cleared *before*
  `await backend.cancelJob` (`:108`), restored on error (`:113`); saved through
  `byID.values.first?.modelContext` (`:118`), not the `context` parameter. Cleared by
  `CapsuleStore.seal` (`:131`) and `normalizeSealHours` (`:375`); restored by `Capsule.restore`
  (`Capsule.swift:175–196`); cleared en masse by Settings › Delete my cloud data
  (`SettingsView.swift:418–419`). Read by the planner (`NotificationPlanner.swift:59`) and the
  upsert guard (`SealDeliveryService.swift:88`). Mirrored by CloudKit (in Production since
  2026-09-05), so a stamp written on one device drops the local reminder on all of them. Any
  main-context save during the request (`ContentView.refreshAndSync` at `:610`, every user write,
  autosave) persists the in-flight claim; `URLSession.shared` can hold the request ~60 s.
- **Unseal:** `CapsuleStore.unseal` leaves the stamp alone on purpose so the cancel path runs.
- **Tokens:** registered only when permission is authorised/provisional/ephemeral
  (`SoundpostAppDelegate.swift:31–40`, `NotificationCoordinator.requestAuthorization:120–134`);
  the delegate hands the token to `Self.registrar`, a weak static set in a `.task`
  (`SoundpostApp.swift:79`). The token arrives after an async settings read and a main-actor hop
  (`SoundpostAppDelegate.swift:24–64`), so the `.task` has almost always run; if it has not, that
  launch's token is dropped and the next launch re-registers. Low severity.
  The app upserts far jobs without regard to tokens (`SealDeliveryService.reconcile:64–67`); that
  is correct for a multi-device user (a job is per `user_key`, tokens are per device), but it
  leaves orphan jobs for a user with no token anywhere.
- **Server** (`backend/supabase/functions/send-due-notifications/index.ts`, `state.ts`,
  `apns.ts`; migrations `0001`, `0002`): a due job with no token → `mark_job_deferred('no_tokens')`,
  `next_attempt_at += 1 h`, `attempts` unchanged, **forever** (`index.ts:151–159`,
  `0001…sql:305–318`, `state.ts:35–47`). APNs 410 / `BadDeviceToken` / `Unregistered` prunes the
  token (`apns.ts:154–157`, `index.ts:191–195`); other errors back off and dead-letter after 6.
  No row is ever deleted; no token sweep exists (a comment in `DeliveryRegistrar` refers to one).
  The Deno tests (`state_test.ts`, `apns_test.ts`, …) are not run by CI. Live rows (2026-11-08):
  3 pending jobs (2 without a token), 2 production tokens.
- **Launch order** (`SoundpostApp.swift:152–248`, the RootView `.task`, which also runs while
  onboarding is on screen): remote-change / account / sync monitors start → export scavenges →
  `AudioOrphanAudit.report` → `ListeningConsentStore.applyToDevice` (throw ⇒ `mayListen = false`
  for this launch) → `await notifications.sync` → `hasAnswer`, `hasStanding = answered ||
  hasRecordedHere` → `guard mayListen && hasStanding` → `SoundprintRemediation.drain` →
  `await SoundprintBackfill.drain()`. No test reads this file. Sibling tasks
  (`runBackfill` → `AudioMigrator`, `ContentView.refreshAndSync`) are unordered with it.
- **Standing seed:** `SoundAnalysisPreferences.hasRecordedHere` (`:143–149`) returns true if the
  key is set **or** `hasCompletedOnboarding` is true; `hasStanding` is persisted and only ever set
  to true. On a phone set up as new and signed into iCloud, launch 1 runs during onboarding
  (standing false — protected); after onboarding completes, launch 2 seeds standing from
  onboarding even if the consent row has not imported yet, and with the default `mayListen` the
  remediation and backfill analyse the imported library of someone who had said no (the labels
  are erased again when the row arrives — `ListeningConsentStore.swift:237+`). The test
  `ListeningConsentTests.anUpgradedInstallInheritsStandingFromOnboarding` (`:248`) pins today's
  behaviour.
- **Reminder promises:** `SealSheet.promise` and capture's seal row use `canPromiseAReminder`;
  capture's echo row uses `remindersWouldBeDelivered`; the detail seal uses the `granted` result;
  **the edit sheet's "Remind me of this later" (`CapsuleEditSheet.swift:118–135`) uses nothing**.
- **Sentry:** the only events since 1.10.0 are two `CloudKit sync error, not surfaced (domain 2,
  code 3, ck 3)` — `networkUnavailable`, i.e. an offline device. The project stores city-level
  geo on every event (IPs are scrubbed at org level); the privacy label declares no location.
- **Store:** `StoreService.loadProducts`'s retry calls itself while `isLoading` is still true
  (`StoreService.swift:125–148`), so it returns at once and never retries. Dormant (Pro is off
  sale, `loadProducts` returns at `:124`).

---

## 4. Design decisions

### 4A. S0 — witness the send, not just the schedule

The server half is witnessed (the poller claimed a due job). What remains is APNs reaching a
phone. Procedure (Jason, with read-only queries prepared by the agent in §13):
1. **First**, read-only: that phone's `user_key` already has a row in `device_tokens` (the agent
   matches it by the job the phone created before, `367e950d…`, or by a fresh job). No token ⇒ a
   two-day wait ends in `no_tokens` (review R2-7); fix registration first (open the app once with
   notifications allowed, re-check).
2. On a phone running the **App Store** 1.10.0 with notifications **allowed** for Soundpost, seal
   a capsule in the calendar to **two days from now** (not a Quick pick, not tomorrow — the
   09:00 normalisation can land it inside the 24-hour horizon, where no server job is written),
   then read the new job row under the same `user_key`.
3. **Do not open Soundpost on any device on that iCloud account from 24 hours before the due time
   until the push arrives.** (Until S1 ships, opening it in that window is exactly the defect
   M21 fixes — and if the app is opened, the local reminder and the push are indistinguishable.)
4. After the push: re-read the row — `status = 'sent'` is the witness. Then, from a killed app,
   tap the notification (cold-launch deep link).

If the row reads `failed` or the token was pruned, S0 becomes the investigation; it does not
gate S1–S4, but S6 records the outcome either way.

### 4B. S1 — re-plan after delivery changes; stamp only after the server answers

**Re-plan from fresh data.** `SealDeliveryService.reconcile` returns whether it changed any stamp.
When it did, `NotificationCoordinator.sync` **fetches the capsules again from `context`** (never
the pre-await `capsules` argument — a sync that ran during the network wait may have changed
them), rebuilds the copy digests and rejection index from that same fresh array, plans, and
reconciles the scheduler under a **new generation taken on the main actor at that moment**. **If
the fresh fetch throws, the re-plan is abandoned** and the schedule left as it is (a notice is
logged): an empty array would plan nothing and the scheduler would remove every pending request
(review R2-1). Extract the plan-and-reconcile half of `sync` into one private function so the
first pass and the re-plan cannot drift apart. Because the data is fresh, it is right for this plan to win over any sync that
started during the wait (review R1-2: a new generation over the *stale* array would have
overwritten a newer sync's plan). Do not move the delivery reconcile ahead of the local plan: the
local plan must not wait on the network (offline-first). Do not rely on adding the stamp to
`sealSignature` alone: it re-syncs only when the gallery's `@Query` observes the change, which a
background or remote-change sync does not guarantee.

**Stamp after the answer; one in-flight set for both directions.** Replace both claim-before-await
writes with a main-actor `inFlight: Set<UUID>` on `SealDeliveryService`: a capsule in it is
skipped by **both** the upsert loop and the cancel loop (review R1-3), inserted synchronously
before the await, removed in a `defer`. After `upsertJob` returns, a fresh fetch decides:

| After the upsert, the store holds… | Do |
|---|---|
| the capsule, still a far seal, same `sealUntil` and `sealTimeZoneID` | stamp `serverJobSyncedAt = now`, save through `context` |
| the capsule, still a far seal, but a different instant or zone | leave unstamped — the next reconcile upserts again and the server re-arms the row (`unique (user_key, capsule_id)`, re-arm on a changed `wall_clock`/`time_zone`, `0001_m10_delivery.sql:152–205`) |
| the capsule, no longer a far seal (unsealed, resurfaced, inside the horizon) | enqueue a pending cancel, then `cancelJob` now (in-flight guarded; resolves on success). The next reconcile cannot see it (no stamp), so the drain's rule changes from "still stored ⇒ resolve without cancelling" to "still stored **and still a far seal** ⇒ resolve; otherwise cancel" (review R1-1) |
| no capsule (deleted during the await) | the same: enqueue, then `cancelJob` now (review R2-4) — the delete's own cancel may have reached the server *before* this upsert re-created the row |

"Still a far seal" is one predicate shared with `SealDeliveryRouter.desiredJobs`
(`state == .sealed`, `sealUntil` more than `localHorizon` after `now`), evaluated by a fresh fetch
that returns `nil` when the store cannot answer (then: keep the entry, decide nothing). It takes
the `now` the reconcile was called with — `drainPendingCancels` gains `now:` and `horizon:`
parameters passed down from `reconcile(capsules:in:now:)`, never `Date.now`, or tests with a fixed
clock misclassify (review R2-2). The M20 delete path is unchanged and still safe: a kill between
`enqueuePendingCancel` and the save leaves a stored far seal, which the drain resolves without
cancelling.

The cancel loop keeps the stamp until `cancelJob` succeeds, then clears it and saves. Save through
`context`, not `byID.values.first?.modelContext` (`:118`).

**Test seam.** `NotificationCoordinator` builds its scheduler on `UNUserNotificationCenter.current()`
inside `override init()` (`NotificationCoordinator.swift:113`), so no test can see what `sync`
schedules. Add an internal `init(center: UserNotificationScheduling, delivery: SealDeliveryService?)`
used by tests (the default `init()` keeps today's wiring), so the S1 tests drive the real `sync`
against the `HoldingCenter` fake and the spy backend (review R2-3). `HoldingCenter` is `private` to
`ReconcileOverlapTests.swift:12` today; move it to `SoundpostTests/DeliveryTestSupport.swift` as an
internal type rather than copying it (review R3-1).

**Token handoff at launch (cheap hardening, low severity).** Set `SoundpostAppDelegate.registrar`
in `SoundpostApp.init`, where `CaptureRequests.coordinator` is already set, rather than in a
`.task`, so no ordering assumption is left.

**Tests (all must fail on today's code):**
- *The last day:* a far seal stamped as server-owned; sync at `due − 23 h` with the spy backend →
  assert the scheduler holds a request for that capsule after that one sync. (Today: none.)
- *Seal and never reopen:* the sync that upserts a far seal → after it, no local request for that
  capsule remains (today the local one stays until the next sync — a duplicate on the day).
- *Never answers:* a backend whose `upsertJob` suspends forever (a held continuation —
  `SpyDeliveryBackend` has no such mode yet); save the context mid-flight; a fresh
  `SealDeliveryService` on the same store must call `upsertJob` again and the planner must still
  schedule the local reminder.
- *Changed during the await:* one case per row of the table above.
- *Overlap:* a second reconcile while a cancel is in flight sends no second `cancelJob`.
- *Fresh re-plan wins correctly:* sync A suspends in the delivery reconcile; sync B (an echo edit)
  applies; A's re-plan must include B's change.
- The M19 64-slot baseline (`AlmanacTests.theAlmanacCannotEvictASealFromTheBudget`) stays equal;
  every existing `SealDeliveryTests` case stays green (all of them assert after `reconcile`
  returns — review R1-8).

### 4C. S2 — `LaunchSequence`, order-only

Extract the RootView `.task` body's ordered steps into `LaunchSequence`, which **owns the
production step implementations** given its dependencies (store, coordinator, monitors), so
`SoundpostApp.swift` calls only `LaunchSequence(…).run()`; tests construct it with a `Steps`
value of closures instead (review R1-6). Behaviour change: **none** — the commit must be
reviewable as a move. Tests record call order with fakes and assert: the exact
order; a throwing consent read ⇒ no remediation, no backfill, sync still runs; no standing ⇒ no
drains; the post-consent sync comes after consent. A source guard asserts `SoundpostApp.swift`
calls `LaunchSequence.run` and contains none of the step calls directly (so a step cannot be
re-added beside it). The sibling tasks stay where they are; document that their order relative to
the sequence is not guaranteed and why that is safe (§3).

### 4D. S3 — standing is earned

Replace the getter's live seed with a **one-shot, non-destructive migration**, run as the first
step of `LaunchSequence` before standing is read: if the marker key
(`sound.standingSeedMigrated`) is absent, then **only if** `sound.hasRecordedHere` is unset and
`hasCompletedOnboarding` is true *at that moment*, set `hasRecordedHere = true`; write the marker
either way. Never write `false` (review R1-5: an existing `true` must survive). All three keys are
read and written through `SoundAnalysisPreferences.defaults`, never `UserDefaults.standard`, so the
task-local test suite (`TestSupport.withIsolatedListeningPreference`) isolates them (review R2-5).
The getter then returns only the stored key. Effect: an install that finished onboarding before
1.11.0 keeps its standing (as today); an install that finishes onboarding after 1.11.0 is
installed gains standing only by recording here or by an answered consent row. An iCloud/Finder
backup restore carries the keys with it, which is correct (it is the same history). Rewrite
`anUpgradedInstallInheritsStandingFromOnboarding` into two tests (upgrade keeps it; new install
does not) and add the phone-set-up-as-new sequence from §3 as a test. The safe direction for a
mistake here is *less* standing. Default assumed; §8 D4 lets Jason choose "drop the seed
entirely" instead.

### 4E. S4 — honesty and noise

- **Edit sheet:** when the echo is on, show the same notice capture's echo row shows, by the same
  rule (`remindersWouldBeDelivered`; the sheet gains `@Environment(NotificationCoordinator.self)`,
  which it does not read today — review R2-6) — reuse the existing string; no new copy unless the existing
  sentence is not literally true in the edit context (then add one, translated).
- **Settings › Delete my cloud data:** its sentence "…fall back to this device's local schedule"
  (`SettingsView.swift:105`) is true only with permission; reword or qualify, translated.
- **Expected network errors:** `CloudSyncMonitor` stops reporting `CKError.networkUnavailable`
  and `.networkFailure` (outer or underlying) — an offline phone is not a fault; keep the local
  log line. Test by the existing report seam.
- **CI survives a GitHub release-asset outage.** On 2026-11-08 CI went red four times on
  docs-only commits because `github.com/getsentry/sentry-cocoa/releases/download/8.58.3/*.xcframework.zip`
  answered 504 (GitHub's status page said all systems operational). Cache the resolved Swift
  packages between CI runs with the first-party `actions/cache`, keyed on `Package.resolved`, so a
  warm run downloads nothing; a cold run (key change) can still fail and is retried by hand. Verify
  the cache is actually hit (log line) and that a key change still resolves. Drop-able.
  (Already done on 2026-11-08, `db408a5`: `check-debug-only.sh` prints the build log's error lines
  and tail when the Release build fails twice — before that, CI said only "see
  build/release-check.log".)
- **Store retry:** make the retry a loop inside one `isLoading` window (or reset the flag before
  re-entering) behind an injectable product loader; dormant while Pro is off sale, so this is
  test-only behaviour. Keep `ProOfferTests` green.

### 4F. S5 — the delivery server stops retrying forever

**SQL only — no Edge Function change, so nothing to deploy but the migration** (review R1-4: a
change in `index.ts`/`state.ts` would also need `supabase functions deploy`, and the poller's
`JobRow` does not even select `wall_clock`/`time_zone`). Migration `0003_m21_hygiene.sql` (in the
repo; **applied to Production only on Jason's word**) adds one `security definer` function and one
nightly `pg_cron` job, `m21_delivery_hygiene` (idempotent unschedule-then-schedule, as `0002`):
- a `pending` job whose `last_error = 'no_tokens'` and whose fire instant is more than 7 days past
  settles as `failed` with `last_error = 'no_tokens_expired'`. The fire instant is computed with
  the same throw-proof guard `is_job_due` uses (a malformed `time_zone` must not abort the batch);
  the user still gets the local reveal when they next open the app;
- `sent` and `failed` rows older than 90 days (`updated_at`) are deleted;
- touches only `public.notification_jobs`; no other app's tables or cron jobs.
A SQL test script (`backend/supabase/tests/0003_hygiene_test.sql`, runnable against a local
`supabase start` database) seeds rows across the boundaries and asserts the outcome; the agent
runs it locally if the Supabase CLI and Docker are available, otherwise records that it could not.
CI: optionally run the existing Deno tests (`deno test backend/supabase/functions`) via
`brew install deno` on the macOS runner — no third-party action; drop it if it costs more than a
few minutes of CI.

### 4G. S6 — the release

`MARKETING_VERSION 1.11.0`, build 23. Release notes in three languages describe only what a user
can notice (the seal reminder on its day; the edit-sheet notice; the consent fix only if it can be
said calmly and truly). Listing unchanged unless a claim changes. Promotional text: push
`metadata/*/promotional_text.txt` (empty on App Store Connect since 1.9.0) only if §8 D6 says
yes. Clean Xcode 27 gate, CI green, `build-upload-asc.sh`, `asc.py` attach/submit,
`releaseType MANUAL`; the release on Jason's word.

---

## 5. Work breakdown

1. **S0** starts day 1 (Jason) and runs in parallel.
2. **S1** → **S2** → **S3** → **S4** → **S5** → **S6**. S3 depends on S2 (the migration is a
   `LaunchSequence` step).
3. S6 does not wait for S0 or for S5's Production apply; it records both outcomes.

---

## 6. Privacy / legal delta

- S1 sends nothing new; it sends the same job later and cancels orphans sooner.
- S3 *reduces* analysis on a phone set up as new before its consent row arrives.
- S5 deletes server rows (sent/failed jobs older than 90 days) — less retained data; the privacy
  policy's delivery section already describes these rows; no wording change expected (check).
- Sentry geo (§8 D7) is a settings decision with a possible privacy-label consequence.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A re-plan inside `sync` races a newer sync | new generation taken on the main actor at re-plan time; turnstile skips the older |
| The re-plan's fresh fetch fails and plans nothing | abandon the re-plan on a throw; never plan from `[]` (R2-1) |
| In-memory in-flight set lost on a kill | that is the point: nothing persisted, so the next launch upserts again; the local reminder stays scheduled meanwhile |
| Duplicate push + local on the day during the transition | the post-upsert re-plan removes the local request; receipt-time dedup remains |
| `LaunchSequence` refactor changes behaviour | order-only commit, call-order tests, a source guard, privacy reviewers' lens in §12 |
| Standing migration revokes standing an upgraded user had | migration copies today's effective value before switching the getter; tests for upgrade and new install |
| Server migration on a shared Production project | SQL only, tested against a local database; applied only by Jason; idempotent; touches only `notification_jobs` and its own cron job |
| Expected-error filter hides a real outage | only `networkUnavailable` / `networkFailure`; everything else still reported once per kind per launch |

---

## 8. Human-in-the-loop (needs Jason)

**Steps**
- **S0** delivery witness (§4A) — day 1.
- **S5** apply `0003_m21_hygiene.sql` to Supabase Production (or say no).
- **S6** "release" — the only public, irreversible action.

**Decisions** (M21 assumes the default in **bold**)
- **D1 Pro:** **A keep hidden** (unchanged from M20).
- **D2 Growth lever for M22 — DECIDED 2026-11-08: yes.** Jason: "D2 同意，M22 做小组件". M22
  builds a launcher widget + an iOS 18 Control Center control in one widget-extension target (a
  launcher shows no data, so it needs **no** App Group). M21 still adds no target (rule 1.5).
- **D3 Server hygiene migration:** **apply `0003_m21_hygiene.sql` after review** (SQL only; no
  function deploy) / leave as is.
- **D4 Standing seed:** **one-shot migration** (§4D) / drop the seed entirely (upgraded installs
  that never recorded lose standing until their consent row or first recording).
- **D5 App Store Connect analytics report request** (one POST, aggregated, opted-in): recommended
  **yes** — Sales and Trends gives downloads only; sessions come from Sentry and include review
  devices.
- **D6 Promotional text** (no review needed): recommended **yes**, from the repo's file.
- **D7 Sentry:** turn off city-level geo for the project (and decide whether the privacy label
  needs a change).
- **D8 TestFlight internal group** (carried from M20 D6): recommended **yes** — future witnesses
  without touching the App Store build.
- **D9 Repo hygiene** (deletions are yours): `build/` holds 250 MB in iCloud-synced `~/Documents`
  (376 logs, `Soundpost 2…9.xcarchive` conflict copies, five copies of js's store); `.git/index 2`
  and empty `metadata/* 2` folders; branches `release/1.6.1`, `release/1.6.2` (the §11L
  carve-out record — you wanted to revisit it in person) and the merged
  `chore/build-roots-2026-10-15`; worktree `.claude/worktrees/dazzling-satoshi-fb69f2` (one WIP
  commit, likely superseded by M20 S1's dSYM gate).

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| Serialised scheduler reconcile with generations | `ReconcileTurnstile`, `NotificationCoordinator.syncGeneration` (M20 S3) |
| Fresh existence check before a delivery decision | `SealDeliveryService.isStored`, `drainPendingCancels` (M20 S2) |
| Durable cancel of an orphan job | `DeliveryPreferences.enqueuePendingCancel` / drain (M10 §S4) |
| Spy backend for delivery tests | `SpyDeliveryBackend` (`DeliveryTestSupport.swift`) — add a suspend mode |
| A notification centre whose `add` can be held | `HoldingCenter` (`ReconcileOverlapTests.swift:12`, private today — move it beside the spy backend) |
| Isolated preferences in async tests | `TestSupport.withIsolatedDeliveryPreferences`, `withIsolatedListeningPreference` |
| Source-shape guard pattern | `CaptureLaunchTests`, `WriteFailureViewGuardTests`, `ProOfferTests` |
| Mutation harness | M20 §13 (`mutate.py` pattern: cp snapshot, apply, `-only-testing`, restore, `cmp`) |
| Shared build packages | `scripts/lib/build_cache.sh` (`CLAUDE.md`) |
| Release tooling with guards | `scripts/release-preflight.sh`, `build-upload-asc.sh`, `asc.py` (M20 S1) |

---

## 10. Acceptance criteria

- §0 success list holds; S0's outcome and S5's apply decision recorded in §13.
- Every new test has a recorded control mutation that made it fail.
- CI green on the final commit; `MIN_TESTS` ≥ the final count.
- 1.11.0 submitted through the guarded tools; release on Jason's word.

---

## 11. Out of scope / M22

- **M22's headline (D2, approved):** a Home Screen / Lock Screen launcher widget and an iOS 18
  Control Center control in one new widget-extension target, opening capture idle through the
  existing `CaptureRequests` → `CaptureLaunchRoute` path (M20 S5). A content widget (Coming up /
  On this day) needs an App Group and a privacy decision — scope it inside M22.
- Live Activities (conflicts with foreground-only recording), capture-prompt notifications
  (rule 1.2).
- Pro, whichever way D1 goes; the theme-undo gap (M19 §11).
- `sealedAt`; the orphan sweep; rejection identifier migration; Swift 6 strict-concurrency
  re-measure (`docs/SWIFT6-TRIAL.md` dates from M12); the `CLGeocoder` → MapKit branch; Xcode 27
  on CI when runner images ship it.
- Sibling devices after "Delete my cloud data" send one failing upsert per far seal per sync
  (documented as intended in `0001`; load only).

---

## 12. Review record

### Round 1 — Gemini 3.8 Flash (high), via `agy`, 2026-11-08

Confirmed the headline defect by its own trace (sync plans at `:152`, the delivery reconcile cancels
and clears at `:103–118`, `sealSignature` ignores the stamp). Eight findings, each checked against
the code before acting:

| ID | Finding | Verdict | Change |
|---|---|---|---|
| R1-1 | Queuing a cancel for a *changed* capsule does nothing: the drain resolves without cancelling when the capsule is still stored | **partly right.** A changed instant re-arms the same server row on the next upsert (`unique (user_key, capsule_id)`, `0001:152–205`), so no orphan. But a capsule unsealed or brought inside the horizon during the await would keep its job | §4B table: cancel now, and the drain cancels a stored capsule that is no longer a far seal |
| R1-2 | A new generation over the stale `capsules` would overwrite a newer sync | right | §4B: re-plan from a fresh fetch |
| R1-3 | The in-flight set must guard the cancel loop too | right | §4B |
| R1-4 | Server change needs an Edge Function deploy; `JobRow` lacks the instant | right | §4F: SQL-only nightly job, nothing to deploy |
| R1-5 | The standing migration could overwrite an existing `true` | right | §4D: non-destructive |
| R1-6 | Closure injection contradicts the source guard | right | §4C: `LaunchSequence` owns production steps |
| R1-7 | `localHorizon` is on `SealDeliveryRouter` | right | §0 |
| R1-8 | No existing test asserts mid-await | right | §4B wording |

Verdict: CHANGES REQUESTED → revised.

### Round 2 — Gemini 3.8 Flash (high), via `agy`, 2026-11-08

Checked every round-1 change against the code: the delete path stays safe under the new drain
rule, the fresh re-plan keeps the turnstile's newest-wins contract, local scheduling still runs
before the network, the standing migration closes the gap, the SQL-only job needs no deploy. Seven
findings, all confirmed against the code:

| ID | Sev. | Finding | Change |
|---|---|---|---|
| R2-1 | major | A failed fresh fetch would plan `[]` and remove every pending request | §4B: abandon the re-plan on a throw; digests from the fresh array; §7 |
| R2-2 | major | "Still a far seal" needs the reconcile's `now`, not `Date.now` | §4B: `drainPendingCancels(now:horizon:)`, one shared predicate |
| R2-3 | major | `NotificationCoordinator.init()` hard-wires the system centre (`:113`); the S1 tests cannot see what `sync` schedules | §4B: an internal injecting init |
| R2-4 | minor | A capsule deleted during the await should be cancelled now, not only queued | §4B table |
| R2-5 | minor | The migration must use `SoundAnalysisPreferences.defaults` | §4D |
| R2-6 | minor | The edit sheet has no `NotificationCoordinator` in its environment | §4E |
| R2-7 | minor | S0 should confirm a token before the two-day wait | §4A step 1 |

Verdict: CHANGES REQUESTED → revised. Also recorded: Jason approved §8 D2 (M22 builds the widget).

### Round 3 — confirmation, Gemini 3.8 Flash (high), via `agy`, 2026-11-08

Checked each round-2 change against the files it touches and found every one correct, sufficient
and implementable, with no new problem; it confirmed the edit-sheet notice can reuse capture's
existing echo string, so no new translation. One minor finding, confirmed and applied:

| ID | Sev. | Finding | Change |
|---|---|---|---|
| R3-1 | minor | `HoldingCenter` is `private` to `ReconcileOverlapTests.swift:12`; the S1 tests need it | §4B, §9: move it to `DeliveryTestSupport.swift` |

**Verdict: APPROVE.** No blockers remain.

### After approval (2026-11-08)

CI went red on the plan commit itself (`271095b`, docs only) at the debug-only gate, twice on
re-run, on the same runner image (`macos-26-arm64`, `20261102.0473.1`) that had passed hours
earlier. The gate only said "see build/release-check.log". `db408a5` makes it print the log, which
showed the cause: GitHub answering **504** for Sentry 8.58.3 release assets. Reproduced from this
Mac with `curl`; by 19:26 JST every `github.com/<owner>/<repo>/releases/download/…` URL answered 504,
other projects' too (`cli/cli`), on the first hop, while githubstatus.com still said "All Systems
Operational". The last green run is `7b3e1d5`; `271095b` and `db408a5` are red only for this. Not a
code defect. Added to S4 as a drop-able tooling item: cache the resolved packages in CI.

---

## 13. Build record

### S0 — the APNs witness (Jason; runs in parallel)

**Before the witness, 2026-11-08 20:10 JST** (read-only; key hashes are 8-character md5 prefixes):

| table | rows |
|---|---|
| `device_tokens` | `367e950d` production, created and last updated **2026-10-07 07:54 UTC**; `cefa75e3` production, 2026-10-23 |
| `notification_jobs` | `525b7989` 2027-09-15 LA `pending`; `367e950d` 2028-06-09 Shanghai `pending`; `690e6cb9` 2026-11-07 LA `pending`, `no_tokens` |
| `delivery_optouts` | `b423c1b2`, `7f251443` (unchanged since M20) |

`367e950d` is the phone M20 S0 used (Asia/Shanghai), and it has a production token — but
`register_device_token` sets `updated_at = now()` on every launch's re-registration
(`DeliveryRegistrar.registeredToken` is memory-only), so a row last touched on 2026-10-07 says
that phone has not opened Soundpost with notifications allowed since. Steps sent to Jason in
Chinese: open the App Store build once with notifications allowed (the token row's
`updated_at` must move to today — that is the step-1 check), seal a capsule to **2026-11-10**
in the calendar, do not open Soundpost on any device of that account from 2026-11-09 09:00
Shanghai until the push arrives, tell the agent before tapping it (opening the app deletes the
row — `cancel_notification_job` is a `delete`), then tap it from a killed app.

### S1 — the seal delivers on its day

**What changed**

- `SealDeliveryService.reconcile` returns whether any `serverJobSyncedAt` changed, and
  `NotificationCoordinator.sync` re-plans when it did: a **fresh fetch** from `context`
  (`fetchCapsulesForReplan`, a seam only so a test can make it throw), digests and the
  rejection index rebuilt from that array, under a **new generation** taken on the main actor.
  A throwing fetch abandons the re-plan with a logged notice. The plan-and-reconcile half of
  `sync` is one private function (`planAndReconcile`) used by both passes.
- The claim-before-await is gone from both loops. A main-actor `inFlight: Set<UUID>` skips a
  capsule in **both** the upsert and the cancel loop (and the drain). The upsert is
  `upsertUntilSettled`: the job is built from a fresh fetch at the moment it is sent; after the
  server answers, a second fresh fetch decides, per the §4B table — same far seal → stamp `now`;
  still far but another instant or zone → **send that at once**, still in flight (at most three
  sends per reconcile); no longer a far seal, or gone → `cancelOrphan` (enqueue the durable
  cancel, then cancel now, resolve on success); the store cannot answer → queue the cancel (the
  drain lets it be if it is still the same far seal). Nothing is stamped once "Delete my cloud
  data" has opted the device out. The cancel loop keeps the stamp until `cancelJob` succeeds,
  then clears it on the freshly fetched object. Everything saves through `context`.
- `SealDeliveryRouter.desiredJob(for:now:horizon:)` is the one "still a far seal" rule;
  `desiredJobs` maps it, and the post-upsert check and the drain ask it with the reconcile's
  `now` (`drainPendingCancels(userKey:in:now:horizon:)`, never `Date.now`). The drain now
  resolves without cancelling only a stored capsule that is **still a far seal**; a stored
  capsule that is not is cancelled. The M20 delete path is unchanged: a kill between its
  enqueue and its save leaves a stored far seal, which the drain still resolves untouched.
- `NotificationCoordinator.init(center:delivery:)` (DEBUG) drives the real `sync` against a
  stand-in centre; it does not take the system centre's delegate. `HoldingCenter` moved from
  `ReconcileOverlapTests.swift` (private) to `DeliveryTestSupport.swift`. `SpyDeliveryBackend`
  can hold the next upsert or cancel on a continuation (released, released by throwing, or
  never), and is lock-protected for it.
- `SoundpostAppDelegate.registrar` is set in `SoundpostApp.init`, not in a view's `.task`.
- `CapsuleActions.delete`: a failed delete resolves the queue entry only if it added it.

**Deviations** (each from the review below, or implied by the plan):
- The §4B table's "different instant or zone → leave unstamped, the next reconcile upserts
  again" is replaced by "send the new job at once". The plan assumed a next reconcile would come;
  the review showed the one the re-seal starts is exactly the one that skips the capsule (it is
  in flight), so the server could push on the old day.
- The drain also skips an id that is in flight, and clears a stamp on a stored capsule whose job
  it cancels (otherwise the cancel loop would send a second cancel in the same reconcile).
- `CapsuleActions.delete` changed (M20 code): see the review's finding 4.


**Review** (one adversarial reviewer on a frozen copy of the diff, told to refute its own
findings before reporting; every finding then checked against the code here). Four confirmed,
all fixed with a test:

| # | Finding | Fix |
|---|---|---|
| 1 | "Delete my cloud data" landing while an upsert is out: Settings purges, opts out and clears every stamp; the late answer stamped the seal again — no device then schedules a local reminder, and an opted-out device never reconciles it. A regression: the old claim was cleared by Settings and never re-written | no stamp once opted out (R1: `aCloudDeleteDuringAnUpsertLeavesNoStampBehind`) |
| 2 | A seal re-sealed while its upsert is out was left unstamped for "the next reconcile" — but the sync the re-seal starts skips it (in flight), so the server could push on the old day, and that push's dedup removes the new local reminder. Also: later iterations sent the snapshot's job, built before earlier iterations awaited | send the new job at once, still in flight (R2: the table's `resealedToAnotherDay` case); the job is built from a fresh fetch when sent (R3: `everyUpsertCarriesWhatTheStoreHoldsWhenItIsSent`) |
| 3 | (minor) The server accepted the job but the store could not be read: nothing recorded the job | queue its cancel; the drain resolves it if it is still the same far seal (R4: `aJobTheStoreCannotConfirmIsQueuedForItsCancel`) |
| 4 | (minor) A failed delete resolved the queue entry unconditionally, erasing a take-back queued before it | resolve only an entry the delete added (R6: `aFailedDeleteLeavesACancelSomeoneElseQueued`) |

Also covered on the reviewer's note that nothing tested it: the drain's in-flight guard (R5:
`aQueuedCancelInFlightIsNotSentTwice`). Its other note — a hold that is never reached let the
next `await` hang — was already fixed: the waits `#require` the hold. Rejected after checking:
"the re-plan can lose to a newer sync" (the generation is taken right after the fresh fetch, with
no await between, so generation order is data order), "the weak static registrar can be dropped"
(`@State` holds it). Left as is and recorded: the delete path's own `cancelJob` resolves its queue
entry on success even if an upsert already in flight re-creates the row afterwards — that upsert's
answer finds the capsule gone and takes the job back itself; only a second, simultaneous failure
of that take-back loses it.

**One flake, found and fixed before commit.** The first clean full run failed
`theReplanAfterTheServerAnswers…` once: its 2-second wait for the held upsert expired, because in
a full run every `@MainActor` suite shares the main actor. The waits now allow 30 s (they return
as soon as the condition holds) and `#require` the hold. `DeliveredOnTheDayTests` and
`ReconcileOverlapTests` then ran 20 times back to back, green.

**Controls**, all run against the final code (`scratchpad/mutate.py`: `cp` snapshot, apply,
`-only-testing` on `DeliveredOnTheDayTests` + `SealDeliveryTests` + `WriteFailureTests`,
`-collect-test-diagnostics never`, restore from the snapshot, `cmp` — all four files compared
equal afterwards). Every run executed 43 tests in 3 suites.

| # | Mutation | Failed |
|---|---|---|
| M0 | **today's behaviour** — no re-plan, claim before the await, no take-back, the M20 drain rule | `aSealOpenedOnItsLastDayStillHasAReminderAfterThatOneSync`, `aSealTheServerTookIsNotAlsoScheduledHere`, `aRequestThatNeverAnswersClaimsNothing`, `whatTheStoreHoldsWhenTheServerAnswersDecides`, `aFailedTakeBackIsRetriedByTheNextReconcile`, `aJobTheStoreCannotConfirmIsQueuedForItsCancel`, `theDrainJudgesAtTheReconcilesOwnMoment`, `upsertFailureRevertsSoLocalBackstopStays` |
| M1 | no re-plan after a delivery change | `aSealOpenedOnItsLastDay…`, `aSealTheServerTook…`, `theReplanAfterTheServerAnswersSeesWhatChangedMeanwhile` |
| M2 | re-plan from the pre-await `capsules` array | `theReplanAfterTheServerAnswers…` |
| M3 | re-plan under the old generation | `aSealOpenedOnItsLastDay…`, `aSealTheServerTook…`, `theReplanAfterTheServerAnswers…` |
| M4 | a failed re-read plans from `[]` | `aReplanThatCannotReadTheStoreChangesNothing` |
| M5 | the stamp claimed before the await (pre-M21) | `aRequestThatNeverAnswersClaimsNothing`, `whatTheStoreHolds…`, `aJobTheStoreCannotConfirm…`, `upsertFailureRevertsSoLocalBackstopStays` |
| M6 | stamped after the answer without the fresh check | `whatTheStoreHolds…` |
| M7 | no take-back for a capsule no longer a far seal | `whatTheStoreHolds…`, `aFailedTakeBack…` |
| M8 | no take-back for a capsule deleted mid-upsert | `whatTheStoreHolds…` |
| M9 | the drain resolves any stored capsule (the M20 rule) | `aFailedTakeBack…`, `aJobTheStoreCannotConfirm…`, `theDrainJudgesAtTheReconcilesOwnMoment` |
| M10 | the drain judges at `Date.now` | `theDrainJudgesAtTheReconcilesOwnMoment` |
| M11 | the cancel loop ignores the in-flight set | `aSecondReconcileDuringACancelSendsNoSecondCancel` |
| M12 | the upsert loop ignores the in-flight set | `aSecondReconcileDuringAnUpsertSendsNoSecondUpsert`, `whatTheStoreHolds…` |
| M13 | the take-back not queued before it is sent | `aFailedTakeBack…` |
| M14 | the registrar handed over in a view `.task` again | `theTokenHandoffIsSetBeforeAnySceneConnects` |
| R1 | no opt-out check after the answer | `aCloudDeleteDuringAnUpsertLeavesNoStampBehind` |
| R2 | a far seal moved mid-request left for "the next reconcile" (the plan's original row) | `whatTheStoreHolds…` |
| R3 | the job sent is the snapshot's, not the store's at send time | `everyUpsertCarriesWhatTheStoreHoldsWhenItIsSent` |
| R4 | an accepted job the store cannot confirm is not queued | `aJobTheStoreCannotConfirm…` |
| R5 | the drain ignores the in-flight set | `aQueuedCancelInFlightIsNotSentTwice` |
| R6 | a failed delete resolves an entry it did not queue | `aFailedDeleteLeavesACancelSomeoneElseQueued` |

Some tests pass on today's code by construction, and are listed here rather than in the plan's
"fails on today's code" set: the two overlap tests and `theReplanAfterTheServerAnswers…`
(today's claim-before-await kept the second request out and the seal out of B's plan; their
controls are M11/M12 and M1–M3), and the tests of seams M21 adds (`aReplanThatCannotRead…`,
`aCloudDeleteDuring…`, `everyUpsertCarries…`, `aQueuedCancelInFlight…`, `aFailedDeleteLeaves…`,
`theTokenHandoff…`), each with its own control above.

**Bars:** 705 tests in 93 suites on a clean Xcode 27.2 build (`xcodebuild clean test` in place),
0 warnings, i18n 100% across 3 catalogs; the almanac's 64-slot baseline unchanged
(`AlmanacTests` green, planner untouched); CI floor raised to 705.

### S2 — `LaunchSequence`: the launch's privacy-critical order in one tested type

**What changed** — a move, nothing else. The root view's launch `.task` body became
`LaunchSequence` (`Soundpost/Services/LaunchSequence.swift`): its production
`init(store:notifications:registrar:remoteChanges:accountChanges:syncMonitor:)` builds one
closure per step from the very calls the `.task` made, and `run()` makes them in the same order
with the same failure handling — every comment, `try`/`try?`/`?? false`, the fail-closed catch
and the early return moved verbatim. `SoundpostApp.swift` now only runs
`await LaunchSequence(…).run()`. Tests build `Steps` from closures that record what ran. The
sibling tasks (`runBackfill` → `AudioMigrator`, the gallery's `refreshAndSync`) stay where they
were, unordered with the sequence; the type's doc says why that is safe (neither reads the
listening mirror or standing; a gallery sync that beats consent is corrected by the re-sync).

**Deviation:** none.

**Review** (one reader, frozen copies, asked to list *any* difference between the old body and
the new code). No behavioural difference: the nine step calls became `steps.x()`, everything
else is verbatim; `store.container`/`mainContext` and the observers are read once at the top of
the task instead of at each use — the same objects, because the old body had no suspension
before its last read. It found two test gaps, both fixed before commit:
- **The run guard passed vacuously.** `contains(".run()")` matched `AudioSelfTest.run()` in the
  same file, so removing `.run()` from the sequence's call — which compiles — passed every test
  (control L13 survived on the first run). It now matches the sequence's own call,
  `await LaunchSequence(…).run()`.
- **The wiring guard was thin**: one call per step, so a fail-open `try?` around the consent
  read, a fire-and-forget `Task {}` around the re-sync, or a dropped observer passed. It now
  requires every call a step makes and forbids `try?` / `Task {` where they would change the
  meaning (L14–L17).
Not acted on, recorded: the guard reads only `SoundpostApp.swift`, so a step re-added in another
view's `.task` would not be caught (the merge path and Settings legitimately call some of the
same functions, so a repo-wide ban would be wrong); the stand-in `recordStanding` in the order
tests never ran the real rule — S3 makes the real rule a static the standing tests run.

**Controls** (`-only-testing:SoundpostTests/LaunchSequenceTests`, 7 tests per run; restored and
compared equal afterwards):

| # | Mutation | Failed |
|---|---|---|
| L1 | observers and export scratch swapped | `theStepsRunInExactlyThisOrder` |
| L2 | orphan count after consent | same |
| L3 | re-sync before consent is applied | same |
| L4 | standing read before the re-sync | same |
| L5 | backfill before remediation | same, `theAccountsAnswerGivesStanding…` |
| L6 | an unreadable consent fails open | `anUnreadableConsentMeansNoAnalysisButStillAResync` |
| L7 | the drains ignore standing | `noStandingMeansNoDrains`, `theAccountsAnswerGivesStanding…` |
| L8 | the drains ignore the consent answer | `anUnreadableConsent…`, `listeningOffMeansNoAnalysis` |
| L9 | an unreadable account answer counts as answered | `theAccountsAnswerGivesStandingAndAnUnreadableOneDoesNot` |
| L10 | a step re-added beside the sequence in `SoundpostApp.swift` | `theAppRunsTheSequenceAndNoStepBesideIt` |
| L11 | the remediation step wired to nothing | `eachProductionStepCallsItsOwnImplementation` |
| L12 | the consent and answered steps cross-wired | same |
| L13 | the app constructs the sequence but never runs it | `theAppRunsTheSequence…` (**survived** the first guard; see review) |
| L14 | the consent step swallows its throw (fails open) | `eachProductionStep…` |
| L15 | the re-sync fired and forgotten in a `Task {}` | same |
| L16 | the account-change observer not started | same |
| L17 | standing not read back | same |

**Bars:** 712 tests in 94 suites on a clean Xcode 27.2 build, 0 warnings, i18n 100%; CI floor
raised to 712.


### S3 — listening standing is earned, not inherited from onboarding

**What changed**

- `SoundAnalysisPreferences.hasRecordedHere` returns only the stored `sound.hasRecordedHere`. It
  no longer reads `hasCompletedOnboarding` — a read that covered every install, new ones too, so
  a phone set up as new gained standing from finishing onboarding and the library pass analysed
  the imported library of someone whose "no" had not arrived yet.
- `SoundAnalysisPreferences.migrateStandingSeed()` takes the old seed once: if
  `sound.standingSeedMigrated` is absent, and only if `hasRecordedHere` was never written and
  onboarding is already complete, it writes `hasRecordedHere = true`; it writes the marker either
  way and never writes `false`. All three keys go through `SoundAnalysisPreferences.defaults`
  (production: `.standard`, where `@AppStorage("hasCompletedOnboarding")` lives), so the
  task-local test suites isolate them.
- It is `LaunchSequence`'s first step. The standing rule became
  `LaunchSequence.recordStanding(answered:)`, a static the production step calls and the
  standing tests run for real (closing S2's review note that the order tests used a stand-in).
- `ListeningConsentTests.anUpgradedInstallInheritsStandingFromOnboarding` became
  `anUpgradedInstallKeepsTheStandingOnboardingGaveIt` and
  `anInstallThatFinishesOnboardingLaterGainsNoStandingFromIt`, plus
  `theStandingMigrationNeverTakesStandingAway`. `LaunchSequenceTests` runs the plan's
  phone-set-up-as-new sequence launch by launch (`aPhoneSetUpAsNewWaitsForItsAnswerBeforeTouchingTheLibrary`),
  the recording path and the upgrade path. `TestSupport.withIsolatedListening` is the async
  form of `withIsolatedListeningPreference` (a new name, so no synchronous call becomes ambiguous).

**Decision:** §8 D4's default (one-shot migration) — Jason has not chosen otherwise. "Drop the
seed entirely" is control T4 below: it would cost every upgraded install that never recorded its
standing until its consent row or first recording.

**Deviation:** none.

**Controls** (`LaunchSequenceTests` + `ListeningConsentTests`, 30 tests per run; restored and
compared equal):

| # | Mutation | Failed |
|---|---|---|
| T1 | the getter reads onboarding live again (pre-M21) | `aPhoneSetUpAsNewWaitsForItsAnswerBeforeTouchingTheLibrary`, `anInstallThatFinishesOnboardingLaterGainsNoStandingFromIt` |
| T2 | the migration is not one-shot | the same two |
| T3 | the migration writes onboarding's value over what is there, `false` included | `theStandingMigrationNeverTakesStandingAway` |
| T4 | the migration never seeds (§8 D4's alternative) | `anUpgradedInstallKeepsTheStandingOnboardingGaveIt`, `anUpgradedPhoneKeepsItsStanding` |
| T5 | the migration runs after standing is recorded | `anUpgradedPhoneKeepsItsStanding`, `theStepsRunInExactlyThisOrder` |
| T6 | the production step does not migrate | `eachProductionStepCallsItsOwnImplementation` |
| T7 | standing ignores the account's answer | `aPhoneSetUpAsNewWaitsForItsAnswer…` |

**Bars:** 717 tests in 94 suites on a clean Xcode 27.2 build, 0 warnings, i18n 100%; CI floor
raised to 717.

### S4 — honesty and noise

**What changed**

- **Edit sheet:** with the echo on and `remindersWouldBeDelivered` false, it shows capture's own
  sentence, "Notifications are off, so this won't reach you until you turn them on."
  (`CapsuleEditSheet.echoNotice`; the sheet reads `NotificationCoordinator` from the
  environment). Capture's other sentence — "A surprise reminder of what today sounded like." — is
  not true of a capsule edited on another day, so the sheet says nothing when the reminder will
  arrive. No new string.
- **Settings › Delete my cloud data:** "…fall back to this device's local schedule." now ends
  "…local schedule, which can alert you only while notifications are on for Soundpost." —
  true in every permission state (JA/ZH-Hans translated; the old key replaced in the catalog).
- **An offline phone is not a fault:** `CloudSyncMonitor` sends nothing to Sentry for `CKError`
  `.networkUnavailable` / `.networkFailure`, outer or anywhere in the underlying chain; it logs
  them locally (`Diagnostics.info` with the same three integers), once per kind per launch. The
  existing retry-storm test used `.networkFailure` as its example of a reportable error; it now
  uses `.zoneBusy` / `.serverRejectedRequest`.
- **Store retry:** `loadProducts()` keeps its off-sale guard and hands off to
  `loadProducts(using:pause:)`, which retries in a loop inside one `isLoading` window (at most 5
  attempts, exponential backoff, stops on cancellation). The recursive retry it replaces
  re-entered while `isLoading` was true and returned at once. Still unreachable while Pro is off
  sale; `ProOfferTests` unchanged and green.
- **CI package cache:** the job names `$RUNNER_TEMP/SourcePackages`, restores it with
  `actions/cache@v6` keyed on `Package.resolved`, and resolves into it once
  (`scripts/lib/build_cache.sh`, which on CI still adds nothing unless the job names a
  directory). Both CI builds — the debug-only gate's Release build and the test run — build from
  it. Whether a warm run really downloads nothing is read from the next run's log (below).

**Deviation:** none.

**Controls** (`HonestAndQuietTests` + `CloudSyncMonitorTests`, 16 tests per run; restored and
compared equal):

| # | Mutation | Failed |
|---|---|---|
| H1 | the edit sheet decides by `canPromiseAReminder` | `theEditSheetDecidesByWhetherTheReminderWouldBeDelivered` |
| H2 | the edit sheet never shows the notice | `theEditSheetSaysWhenAnEchoWillNotArrive` |
| H3 | the edit sheet promises "today" when the reminder will arrive | same |
| H4 | an offline phone is reported to Sentry again | `anOfflinePhoneIsLoggedNotReported` |
| H5 | only the outer error is checked for "offline" | same |
| H6 | the store retry re-enters inside the `isLoading` window (pre-M21) | `aFailedProductLoadIsRetriedUntilItSucceeds`, `aProductLoadThatKeepsFailingStopsAfterFiveTries` |
| H7 | the store retry has no cap | `aProductLoadThatKeepsFailingStopsAfterFiveTries` |
| H8 | the unqualified cloud-delete sentence is back | `theCloudDeleteSentenceHoldsWithNotificationsOff` |
| H9 | the edit sheet computes the notice but never shows it | `theEditSheetDecidesByWhetherTheReminderWouldBeDelivered` |

The CI cache's own check is CI: `build_cache.sh`'s CI branch was exercised locally against the
existing package directory (named → the three package flags; unnamed or `off` → nothing), without
a network resolve.

**Bars:** 723 tests in 95 suites on a clean Xcode 27.2 build, 0 warnings, i18n 100%; CI floor
raised to 723.

**S4's CI cache, witnessed (run 42479733781, `048e1c3`):** cold — "Cache not found", one resolve
into `$RUNNER_TEMP/SourcePackages` in 53 s, both builds used it, 723 tests, "Cache saved". The
whole job took 6 m 2 s, against 8–10 m before. The warm run is S5's (below).

### S5 — the delivery server stops retrying forever (SQL only)

**What changed**

- `backend/supabase/migrations/0003_m21_hygiene.sql`: `m21_job_fire_instant` (the job's fire
  instant, `null` for a zone that cannot be read — the same throw-proof guard as `is_job_due`)
  and `m21_delivery_hygiene(p_now)`, `security definer`, revoked from `public`/`anon`/
  `authenticated`, scheduled nightly at 03:17 UTC as cron job `m21_delivery_hygiene`
  (unschedule-then-schedule, as `0002`). It:
  1. settles as `failed` / `last_error = 'no_tokens_expired'` a `pending` job whose last error
     is `no_tokens`, whose fire instant is more than 7 days past, whose user has **no** token now
     (a token registered since means the poller sends it within the hour), and which no poller
     holds (`locked_at` null or older than 10 minutes);
  2. deletes `sent` and `failed` rows untouched for 90 days.
  It touches only `public.notification_jobs` and its own cron job. Nothing to deploy but this
  file: no Edge Function changed.
- `backend/supabase/tests/0003_hygiene_test.sql` seeds eleven rows across every boundary (6, 7
  and 8 days; a token; a lock; a malformed zone; another error; 89/91 days; a far pending job),
  runs the hygiene at a fixed instant, and asserts each outcome, idempotence, the 90-day cleanup
  of an expired row, the single cron entry and the revoked grants — all inside a transaction
  that rolls back.
- `backend/supabase/tests/run-local.sh` runs it with no Docker or Supabase CLI: a throwaway
  Postgres cluster (Homebrew `initdb`/`pg_ctl`) in `$TMPDIR` on loopback TCP, the smallest
  stubs for Supabase's roles, `extensions`/`vault` schemas and pg_cron's `cron.schedule`, then
  `0001`, `0003` applied **twice**, then every `*_test.sql`. Two macOS traps it handles: the
  postmaster refuses to start without a locale (`LC_ALL=C`), and a Unix socket under a long
  `$TMPDIR` can exceed the path limit (it uses TCP).
- CI gained "Delivery server tests": the Edge Function's 18 Deno tests (`brew install deno`;
  install or network trouble only warns, a failing test fails) and the SQL test when the runner
  already has Postgres (otherwise a notice saying it runs locally).

**Not applied to Production.** §8 D3 is Jason's: the file is reviewed and tested locally; he
applies it to project `gkjwsxotmwrgqsvfijzs` (SQL editor, or `psql` with the project's
connection string) or says no. The privacy policy (`M10-privacy-policy-delta.md`, "Retention &
deletion") promises removal at delete, unseal, resurface and "Delete my cloud data"; this only
removes rows sooner, so nothing it says becomes untrue. A sentence about the 90 days is optional.

**Controls** (each mutation written over the migration, `run-local.sh` run, the file restored
from a snapshot and compared equal):

| # | Mutation | The test said |
|---|---|---|
| Q1 | expires even when the user now has a token | `expired 2 rows, expected 1` |
| Q2 | expires after 5 days | `expired 3 rows, expected 1` |
| Q3 | expires at exactly 7 days | `expired 2 rows, expected 1` |
| Q4 | expires a row a poller holds | `expired 2 rows, expected 1` |
| Q5 | no exception guard: a malformed zone | `time zone "Not/AZone" not recognized` — the whole batch aborts |
| Q6 | expires pending jobs whatever their last error | `expired 2 rows, expected 1` |
| Q7 | deletes after 30 days | `deleted 3 rows, expected 2` |
| Q8 | deletes pending rows too | `deleted 3 rows, expected 2` |
| Q9 | the hygiene left executable by `anon` | `anon/authenticated can run the hygiene` |

**Bars:** no app code changed: 723 tests, 0 warnings, i18n 100% as at S4 (no rebuild needed);
SQL test and Deno tests green locally.

**CI, first run red (`2699069`, run 42480267315), fixed in the next commit.** The new step's
Homebrew Deno was 2.9.8; its TypeScript rejects `body: opts.payloadBytes` (a `Uint8Array`) in
`apns.ts:132` as a `fetch` body, where the local 2.7.5 accepts it. A type-check against an
unpinned Deno, not a test failure — the function runs on Supabase's own pinned runtime. Changing
`apns.ts` would make the repo differ from the deployed function (S5 is SQL-only by design), so
CI runs `deno test --no-check`. **For M22:** fix that line (`new Uint8Array(…)` /
`as BodyInit`) the next time the function is deployed anyway. The same run was the CI cache's
warm witness: "Cache restored from key spm-macOS-caa3ee30…", `cache-hit=true`, no resolve, both
builds pointed at the restored directory.

### S6 — the release: 1.11.0, build 23

**Release notes** (`metadata/*/release_notes-1.11.0.txt`, copied to `release_notes.txt`), only
what a user can notice: the far seal's reminder on its day even after opening the app the day
before ("With notifications on…", because without them nothing reminds anyone), and the edit
sheet's notice. The consent fix (S3) is left out: a user cannot notice it, and the one-line
version of it is not true in every case (recording on the new phone still earns standing).
Listing unchanged; promotional text not pushed (§8 D6 undecided).

**Pre-upload review** — three readers over `7b3e1d5..2699069`, each with its own lens (delivery
and notifications across steps; privacy and the launch path for real upgrading and new users;
release, CI, SQL and copy), each told to refute its own findings before reporting; every finding
then checked here against the code. Nothing that would get the build rejected or mislead a user.

| Finding | Verdict | Done |
|---|---|---|
| A launch before the first unlock after a restart reads empty preferences; the one-shot standing seed would see "no onboarding", write its marker and be spent for good on an upgraded install | plausible, cheap to close | the production step migrates only when `UIApplication.shared.isProtectedDataAvailable`; otherwise next launch (V1) |
| `isOffline` matched a network error anywhere in the chain while the report is keyed on the first `CKError` — a real fault with a network error beneath it would go unreported | confirmed, no live case found | judges the first `CKError` only (H5, H10) |
| A cache that hit is never saved again, and the key ignored the Xcode version: a partial directory, or one another SwiftPM wrote, could stick | confirmed | key includes `EXPECTED_XCODE`; restore and save split, and the save runs only on a miss whose resolve wrote its marker |
| The SQL test empties both tables: sent as one query by a client that stops at the first error (an SQL editor), it could leave the transaction open holding the poller's locks | confirmed in principle | the file's first statement refuses a database that holds any row (checked: a seeded row → "refusing to run") |
| `2699069` red on CI (Deno 2.9.8's type-check) | known | `10ce5bc` green; Deno unpinned — recorded |

**Pre-existing, recorded for M22, not changed in 1.11.0:**
- **Multi-device last day.** A sibling device's sync in a far seal's last 24 hours hands it back
  (cancels the server job — the push for *every* device) and re-plans only its own local
  reminder; another device gets one only if it imports the cleared stamp and syncs in the
  background, which is best-effort. Kept for 1.11.0 because a push to a real phone has still
  never been witnessed (S0) — the local reminder is the proven path. Option for M22 (Jason):
  keep the server job through the day and cancel only on unseal, delete or resurface.
- **Around the due instant** (≈1 minute): a hand-back whose network wait crosses the due time
  re-plans with the sync's starting `now` (a past trigger never fires), and a sync after the due
  time but before the poller claims the job deletes it. Low.
- **Recording on a phone set up as new earns standing** before the account's "no" arrives
  (M15's design, which §4D keeps) — the library pass can then run on the default mirror; the
  labels are erased when the row arrives. Option: drains only on `answered || seeded`, with
  recorded standing governing display only.
- **New phones without a consent row show no labels until they record** (intended by §4D;
  most accounts have no row — a row is written only by a deliberate toggle).
- Lock-screen copy reads `soundprintRaw` regardless of standing; cancels are keyed by capsule id
  only (a stale device can cancel a sibling's re-sealed job); `apns.ts:132` under newer Deno.

**Controls** (all bit): V1 (the seed runs before the preferences can be read →
`eachProductionStepCallsItsOwnImplementation`), H4, H5 (outer error only), H10 (anywhere in the
chain — the first S4 version) → `anOfflinePhoneIsLoggedNotReported`.

**Gate before upload** (clean Xcode 27.2 build, `1.11.0 (23)`): 723 tests in 95 suites; 0 warnings;
i18n 100%; store-metadata, sound-vocabulary and SQL gates green. Two full runs were taken while
another session's work held the machine's load average at 40–46 on 10 cores. The first lost
three tests to it: `theReplanAfterTheServerAnswers…` (its wait for the held upsert ran out at
30 s — now 120 s, which costs nothing when the hold comes sooner) and the two simulator-video
tests. The second lost only `VideoGateTests.playbackStaysFree` — `AddRunningClient failed
(status = -66681)`, `.couldNotStart`, the known local-only simulator-audio failure (memory
`soundpost-test-run-gotchas`; green on every CI run, and in today's earlier clean runs). CI is
the authority for it.

**Build 23** (commit `f5c8ac2`, tag `v1.11.0-b23`, pushed): CI green on `f5c8ac2` (run
42485206493 — 723 executed, floor 723; the cache's new key cold-resolved and was saved right
after the resolve). Archived with Xcode 27.2 on 2026-11-08 ~22:40 JST with the screen locked
(the login keychain stayed open: `no-timeout`, and the codesign probe passed); dSYMs to Sentry
(3 files); uploaded through `exportArchive`; the `Sentry.framework` dSYM warning is the known,
expected one. 1.10.0's archive was copied to `~/Library/Developer/Xcode/Archives/2026-10-08/`
first — the script replaces `build/Soundpost.xcarchive`.

**The preflight was overridden** (`RELEASE_PREFLIGHT_OVERRIDE=yes`), for two refusals that
name files no build reads: the empty iCloud conflict folders `metadata/en-US 2`, `ja 2`,
`zh-Hans 2` (§8 D9, Jason's to delete) and another session's `.claude/scheduled_tasks 2.lock`
(which also made the tree read as "not clean"). Everything else passed: project 1.11.0 (23),
codesign, build 23 new on App Store Connect (newest was 22), Sentry token. The override also
switches off two of the script's own guards, so both were done by hand: HEAD was still
`f5c8ac2` with no tracked change after the archive (so the tag names what was built), and the
dSYM upload's own output says `Uploaded 3 missing debug information files`.

App Store Connect: version 1.11.0 created (`d8b6e6d2-6d00-4e94-a7c1-850688e2d2e7`,
`PREPARE_FOR_SUBMISSION`, `releaseType MANUAL` read back), What's New pushed in three languages;
description, keywords and screenshots inherited (no claim changed).

Build 23 processed `VALID` (2026-11-08 22:46 JST) and is attached to 1.11.0 (`releaseType MANUAL`
read back with build 23 on it). **Not yet submitted.** `asc.py submit` created review submission
`d56ef962-1a35-4092-bb26-dc5e24e3659b` and then App Store Connect refused to add the version to
it (409 `STATE_ERROR.ENTITY_STATE_INVALID`): the age-rating declaration lacks a value for
`socialMedia` — a question Apple added after 1.10.0; its follow-up `socialMediaAgeRestricted` is
also blank, and every other answer is set. That is a declaration to Apple in Jason's name, so it
waits for his answer.

**Submitted 2026-11-09 16:35 JST** (`submittedDate 2026-11-09T07:35:58.951Z`), on Jason's answer
that day ("社交媒体：否，提交审核吧"):

1. `PATCH ageRatingDeclarations/498a5dc2-553b-4118-b935-27e19061fdd5` with `socialMedia: false`
   and nothing else; read back `false` (through `appInfos/{id}/ageRatingDeclaration` — the
   declaration itself allows only UPDATE, a GET answers 403). Every other answer was already set
   and matches the live 1.10.0 declaration. `socialMediaAgeRestricted` stays blank: it follows a
   "yes", and the submission went through without it.
2. `asc.py submit` **failed**: its first step cancels open drafts, and Apple refuses to cancel a
   draft that was never submitted (409 `Resource is not in cancellable state`). The note above
   ("the next `submit` cancels it") was wrong. So the draft was used rather than replaced — the
   same two calls `submit` makes on a fresh one: add version `d8b6e6d2…` (asserted 1.11.0,
   build 23, `releaseType MANUAL` first) as an item of `d56ef962…`, which had none, then PATCH it
   `submitted: true`.
3. Read back: submission `d56ef962…` `WAITING_FOR_REVIEW`; version 1.11.0 `WAITING_FOR_REVIEW`,
   build 23, `releaseType MANUAL`.

Stopped there. `asc.py release` only on Jason's word, after approval.

**Approved** by App Review on 2026-11-09 (`PENDING_DEVELOPER_RELEASE`). **Released 2026-11-10** on
Jason's word ("1.11.0 发布吧"): `asc.py release` → read back `READY_FOR_SALE`. The archive was copied
to `~/Library/Developer/Xcode/Archives/2026-11-08/Soundpost 1.11.0 (23).xcarchive` (identical by
`diff -rq`) before 1.12.0's build can overwrite `build/Soundpost.xcarchive`. The `submit` trap is carried
to M22 (docs/M22-START.md item 9).
