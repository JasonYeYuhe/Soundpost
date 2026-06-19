# Soundpost M9 — Durability: stop losing capsules on uninstall

> Development plan for the next phase. Status feeding in (2026-06-16): **1.1.0 (build 5)
> is `WAITING_FOR_REVIEW`** (the 5.1.1(iv) location-prompt fix). M1–M8.5 shipped. 52 tests /
> 8 suites green, warning-free, i18n EN/JA/ZH-Hans at 100%, zero third-party deps except Sentry.
> This plan refines DEVPLAN.md §M9 into implementation-ready steps, grounded in the current code.

---

## 0. Goal & success statement

**Today, deleting the app erases every capsule** (capsules live only on-device: SwiftData store +
`.m4a` files in Application Support). M9 makes a signed-in user's capsules **survive uninstall and
sync across their Apple devices**, using **CloudKit private database** via SwiftData — with **no
account, no server, no new "collected data."** It is the single most-requested durability fix and
the riskiest migration in the roadmap, so it gets its own milestone.

**Done when:** on a device signed into iCloud, *delete + reinstall restores all capsules including
audio*; a second device shows the same capsules; signed-out / iCloud-full users still get a fully
working **local** app with honest messaging (never a broken or blocking state); the file→Data audio
migration is tested and lossless; the gallery never loads audio blobs into memory; build stays
warning-free with tests green and i18n 100%.

## 1. Non-negotiables (carried from PROJECT.md / DEVPLAN.md)

1. **Offline-first still wins.** CloudKit is a *mirror*, never a gate. No capture, playback, seal, or
   echo may ever require network or an iCloud account.
2. **One audio strategy.** Audio moves to `@Attribute(.externalStorage) var audioData: Data?`
   (→ CKAsset). We do **not** also sync `.m4a` files via iCloud Drive (two reconcilers = bugs).
3. **Additive + lightweight schema only.** CloudKit-mirrored stores reject `@Attribute(.unique)`,
   non-optional new properties without defaults, and heavyweight migrations. Every change is purely
   additive; the file→Data move is an **app-level backfill**, not a `SchemaMigrationPlan` stage.
4. **Honesty over theater.** Update the "no cloud backup — uninstall erases" copy to reflect the real
   iCloud state; never imply guaranteed/permanent storage. Durability ≠ delivery (delivery is M10).
5. **No regression** to the shipped offline experience, tests, i18n, or warning-free build.

## 2. Scope

**IN (this phase):**
- `audioData: Data?` externalStorage field + dual-read playback + tested file→Data backfill.
- Custom `ModelContainer` with CloudKit private DB + an init fallback ladder (iCloud → local → memory).
- iCloud capability / container / push + remote-notification background mode (signing) — see §8 human steps.
- Multi-device notification re-scheduling (mostly verification of the existing reactive path + a gap fix).
- Graceful handling of signed-out (`CKError.notAuthenticated`) and quota-exceeded.
- Honest in-app copy + privacy-policy text update for iCloud.
- Tests for the migration, lazy-load, and planner-over-imported-capsules; manual two-device pass.

**OUT (later milestones — do not build now):**
- Server/APNs cloud-backed delivery (**M10**), monetization/Pro (**M11**), a full Settings screen,
  export, language override, widgets (**M12**), Android/Supabase (revisit only for non-Apple).
- A user-facing iCloud on/off toggle beyond reflecting account state (defer the toggle UI to M12 unless trivial).

## 3. Current state (grounded — cite before you change)

| Concern | Where | Note for M9 |
|---|---|---|
| Production container | `Soundpost/SoundpostApp.swift:49` (`.modelContainer(for: Capsule.self)`) | The **only** line to replace with the CloudKit container. |
| Test containers | each test builds its own in-memory `ModelContainer`; `RootView` makes none under XCTest | **Do not** route tests through CloudKit. Keep in-memory. |
| Demo/screenshot container | `Soundpost/DemoData.swift` (`isStoredInMemoryOnly: true`) | Leave as-is (in-memory, no CloudKit). |
| Model | `Soundpost/Models/Capsule.swift` — all props optional/defaulted, **no** `.unique` | Already CloudKit-legal. Add `audioData` only. |
| Audio storage | `audioFileName: String?` + `Soundpost/Audio/AudioStore.swift` (App Support/`SoundpostAudio`) | Source for the backfill; keep as fallback during transition. |
| Playback | `Soundpost/Audio/AudioPlayer.swift:26` `play(fileName:)` → `AVAudioPlayer(contentsOf:)` | Add a `play(data:)` path; prefer `audioData`, fall back to file. |
| Capture write | `CapsuleStore.markCaptured(...)` sets `audioFileName` | Also populate `audioData` for new capsules. |
| Delete | `CapsuleStore.delete` = `context.delete` only — **audio file is never removed** (orphan leak) | externalStorage blob is deleted with the row → leak goes away post-migration. |
| Scheduling trigger | `ContentView.swift` `.task` + `scenePhase==.active` → `refreshAndSync()`; `sealSignature` `onChange` re-syncs | CloudKit import updates `@Query capsules` → `sealSignature` changes → **re-sync already fires.** Verify + cover the backgrounded-import case. |
| Planner / scheduler | `NotificationPlanner` (64-nearest, pure) + `NotificationScheduler` (reconcile by `capsule.<uuid>|kind|epoch` id) | Works on any `[Capsule]`, including imported ones. No core change expected. |
| Honest copy | `ContentView.swift:81` storage footer ("no cloud backup yet… deleting the app erases them") | Must become iCloud-state-aware. |

## 4. Architecture decisions (the two hard parts)

**A. Audio = ONE strategy, migrated app-side.** Add `@Attribute(.externalStorage) var audioData: Data?`
to `Capsule`. SwiftData stores large external blobs as CKAsset under CloudKit, lazy-faulted on access
— so the gallery `@Query` (which reads `waveformSamples`, an inline small `[Float]`) never loads
audio into memory; only `AudioPlayer` faults `audioData` at play time. New capsules write both
`audioData` (canonical) and, transitionally, keep recording to a temp file then read it into `Data`.
Old capsules are backfilled (§S2). Keep `audioFileName` readable as a fallback until the backfill is
proven, then it simply goes unused (no destructive removal of the property — that would be a
non-additive schema change under CloudKit).

**B. Additive + lightweight only — no heavyweight migration.** Because CloudKit forbids heavyweight
SwiftData migrations, adding `audioData` is an *automatic lightweight* migration (new optional
property). The file→Data copy is **not** a schema stage; it's an idempotent, guarded **backfill pass**.
This is the single riskiest step — own it: copy first, verify the `Data` is non-empty and round-trips
through `AVAudioPlayer(data:)`, save, **then delete the source `.m4a`** (§D, §S2).

**C. CloudKit is a mirror, init never fails the app.** Replace the production container with a custom
`ModelContainer(for: Capsule.self, configurations: ModelConfiguration(cloudKitDatabase: .automatic))`
wrapped in a fallback ladder: try CloudKit-backed → fall back to local-only (no CloudKit) → fall back
to in-memory, logging (Sentry) which rung we landed on. A signed-out or iCloud-disabled user
transparently runs the local rung; their data later mirrors up if they sign in (CloudKit handles this).

**D. Concurrency & rollout are first-class constraints (Gemini review).**
- **`@Model` is not `Sendable`.** Never pass a `Capsule` or the main `ModelContext` across an actor
  boundary (a detached `Task` would fatally crash SwiftData). The backfill runs in its **own
  `@ModelActor`** with an isolated background `ModelContext`; the UI keeps using the main context.
- **No clean two-build rollout — assume backfill and CloudKit ship together.** App Store users skip
  versions, so a user can jump straight from the file-only 1.x to the CloudKit build. The backfill
  must therefore be **safe to run while CloudKit sync is active**: idempotent, batched, and it saves a
  capsule's context **only after** `audioData` is populated (so CloudKit uploads the real asset once,
  never an empty blob first then a large overwrite). Do not promise an "enable CloudKit later" release
  as a safety net — design for coexistence from the first CloudKit build.
- **Delete the source file after verify** (don't "leave it"). `externalStorage` copies the blob into
  the store; keeping the `.m4a` doubles on-disk audio and can fail near the storage limit.
- **Record identity:** each capsule is created once on one device (UUID by construction); CloudKit
  mirrors by its own record id, so there is **no merge/dedup logic to write** in M9. (LWW is a future
  concern — adding an optional `updatedAt` now is cheap insurance, not required.)

## 5. Work breakdown (sequenced; each step compiles + commits)

> Order matters: schema/field first (so the store is CloudKit-shaped), then container, then backfill,
> then multi-device + edge cases, then copy + tests. Each step is independently verifiable.

**S1 — Add `audioData` and dual-read playback (no CloudKit yet).**
- `Capsule.swift`: add `@Attribute(.externalStorage) var audioData: Data?` (optional → CloudKit-legal);
  document it. Initialize to `nil` in `init`.
- `AudioPlayer.swift`: add `play(data: Data)` using `AVAudioPlayer(data:)`; keep `play(fileName:)`.
  A capsule-level `play(_ capsule:)` helper prefers `audioData`, else falls back to the file.
- `CapsuleStore.markCaptured(...)`: accept/populate `audioData` (read the just-recorded temp file into
  `Data`) in addition to `audioFileName`, so **new** capsules are durable immediately.
- *Verify:* unit test — a capsule with `audioData` plays via the data path; one with only
  `audioFileName` still plays via the file path. Build warning-free. Commit.

**S2 — File→Data backfill (riskiest step; must coexist with CloudKit).**
- Implement `AudioMigrator` as a **`@ModelActor`** (its own isolated background `ModelContext` — never
  touch the main context or pass `Capsule` across actors). It fetches capsules where
  `audioData == nil && audioFileName != nil`, and for each: read the file → set `audioData` → **verify**
  non-empty and that `AVAudioPlayer(data:)` constructs → `context.save()` → **then delete the source
  `.m4a`** via `AudioStore.delete`. Process in **small batches** (e.g. 10) to bound memory and to keep
  CloudKit uploads incremental.
- **Idempotent + resumable + CloudKit-safe:** safe to interrupt and to run while the initial CloudKit
  import is in flight; never uploads an empty blob (save happens only after `audioData` is set). Trigger
  it once per launch from the App layer *after* the container is up (kick the actor; it no-ops when
  nothing matches). A missing/zero-byte source file is logged (Sentry) and skipped, not fatal.
- *Verify:* test seeds a file-only capsule → run migrator → `audioData` populated, round-trips, **source
  file deleted**; idempotent on a second run; missing-file capsule skipped without crash; runs on a
  background `ModelContext` without main-actor violations. Reuse `FlowPilot:Models/ModelMigration.swift`
  as a *concept* only (we use a `@ModelActor` backfill, not a `SchemaMigrationPlan` stage).

**S3 — CloudKit-backed container with fallback ladder.**
- New `SoundpostModelContainer.makeProductionContainer()` returning a `ModelContainer` via the
  iCloud→local→in-memory ladder (Sentry-log the rung). Use `ModelConfiguration(cloudKitDatabase:
  .automatic)` (or `.private("iCloud.com.soundpost.Soundpost")`).
- Replace **only** `SoundpostApp.swift:49` to inject this container (`.modelContainer(container)`); keep
  the `#if DEBUG` self-test/demo branches and the under-tests no-container behavior unchanged. **Retain
  the container** on the App so S4 can observe its CloudKit import events and S2 can kick the migrator.
- **Contingency check (P2):** confirm the CloudKit container initializes with `waveformSamples: [Float]`
  defaulted to `[]` (SwiftData maps `[Float]` to a transformable; CloudKit-backed stores can reject some
  schema-level defaults). If init throws a schema-validation error, change it to optional `[Float]?`.
  `Place` (Codable struct) and `CapsuleState` (Codable enum) mirror cleanly; `private(set) var state` is fine.
- *Verify:* app launches and the gallery works on (a) a simulator signed into iCloud and (b) one signed
  out (must land on the local rung, fully functional); CloudKit container init does not throw. Reuse:
  `RoastMate:Shared/SharedModelContainer.swift`, `timeless:TimelessModelContainer.swift`.

**S4 — Multi-device notification re-scheduling (does NOT "fall out" — Gemini correction).**
- The reactive path (`@Query` → `sealSignature` `onChange` → `notifications.sync`) only fires **while
  the UI is foreground**. SwiftUI views are not evaluated in the background, so a sealed/echo capsule
  imported via CloudKit's silent push while the app is backgrounded would **never** get its local
  notification scheduled until the user reopens the app. Do not rely on the reactive path alone.
- **Required:** observe **`.NSPersistentStoreRemoteChange`** at the App layer — it fires when the local
  store is *actually modified by a remote merge* (the correct signal). Do **not** use
  `NSPersistentCloudKitContainer.eventChangedNotification`, which only broadcasts sync *status*
  (setup/import/export start/end/error) and does not guarantee records merged. On a remote-change event,
  trigger `NotificationCoordinator.sync(capsules:)` against a freshly-fetched set (optionally use the
  SwiftData History API to scope *what* changed and skip needless reschedules). This is why §8 adds the
  **Remote notifications** background mode (it lets CloudKit wake the app to import). Keep the foreground
  `.task`/`scenePhase` reconcile as the belt-and-suspenders path.
- **Honest scope:** background wake is itself best-effort (system-throttled) — fine for M9, whose job is
  *durability*, not guaranteed delivery. Far-future guaranteed firing is M10's server. Document that a
  worst case is "notification (re)appears the next time the app is opened."
- *Verify:* unit test — `NotificationPlanner.plan(capsules:)` over a set including an
  "imported-elsewhere" sealed capsule yields the correct request; the `uuid|kind|epoch` identifier
  dedupes a seal that exists on both devices; a test/harness path invokes the import-event handler and
  asserts `sync` is called.

**S5 — CloudKit edge cases (never present as "broken").**
- Surface `CKError.notAuthenticated` (signed out) and quota-exceeded as a *calm, dismissible* state
  (e.g. a one-line note in the storage footer / a non-blocking banner), not an error alert. Local app
  keeps working. Log other CloudKit errors to Sentry (PII-scrubbed), don't surface.
- *Verify:* simulate signed-out launch (local rung) → no scary UI; capture/playback still work.

**S6 — Honest copy + privacy.**
- Rewrite `ContentView.swift:81` storage footer to be iCloud-state-aware:
  signed-in → "Backed up to your iCloud and synced across your devices."; signed-out → keep the honest
  "only on this device… deleting the app erases them" warning. Localize all new strings EN/JA/ZH-Hans.
- Update the hosted privacy policy (repo `JasonYeYuhe/soundpost-site`) to state capsules are stored in
  **the user's own iCloud private database** (not collected by the developer). Re-confirm
  `PrivacyInfo.xcprivacy` needs **no** new entry (no new collected-data type; no new required-reason API).
- *Verify:* i18n stays 100%; privacy page live (200) and links unchanged.

**S7 — Tests.** Backfill (S2), dual-read playback (S1), planner-over-imported (S4), and a guard that the
gallery fetch doesn't fault `audioData` (assert via a `FetchDescriptor` that excludes/doesn't touch the
blob). Keep all existing suites green.

**S8 — Manual on-device verification (cannot be automated).** Two iCloud-signed devices: capture on A →
appears on B; delete+reinstall on A → capsules incl. audio restored; sign out → local-only, no crash;
toggle airplane mode → capture still works, syncs later. Record results in DEVPLAN.md.

## 6. Privacy / legal delta

Storing the user's capsules in **their own** CloudKit private database is **not** "data collection by
the developer," so the ASC privacy nutrition label and `PrivacyInfo.xcprivacy` should be **unchanged**.
Only the **privacy-policy prose** gains an "iCloud sync (your private database)" sentence. (Contrast
M10, which *does* add device tokens + server jobs → real label changes.) Keep PrivacyInfo / ASC label /
policy in lockstep as the project rule requires.

## 7. Risks & mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| **SwiftData concurrency crash** in backfill (`@Model` not `Sendable`) | High | Backfill is a `@ModelActor` with its own context; never pass `Capsule`/main context across actors (§D, S2). |
| **Backfill data loss / corruption** (file→Data) | High | Copy → verify non-empty + `AVAudioPlayer(data:)` constructs → save → *then* delete source; idempotent, resumable, batched; unit-tested; **CloudKit-safe** (must assume it runs alongside first sync — users skip versions). |
| **Storage doubling** (externalStorage copies the blob) | High | Delete the source `.m4a` immediately after verify+save, in the same batch — do not keep both copies (could fail near the device storage limit). |
| **Background-import notification gap** | High | Don't rely on SwiftUI reactive state in the background; observe `.NSPersistentStoreRemoteChange` (not `eventChangedNotification`) to trigger reschedule (S4); needs Remote-notifications bg mode (§8). |
| **CloudKit schema lock-in** (can't change non-additively later) | High | Only additive optional fields now; never add `.unique`; finalize the M9 schema deliberately; promote to Production in the CloudKit Dashboard only after the schema is settled. |
| **Skipped-update rollout** (no clean two-build sequence) | Med | Design backfill + CloudKit to coexist in one build; never upload an empty blob then overwrite (save only after `audioData` set). |
| `[Float]` transformable default rejected by CloudKit | Med | Verify container init with `waveformSamples = []`; fall back to optional `[Float]?` if it throws (S3 contingency). |
| Signing/provisioning for iCloud+push | Med | New entitlements (iCloud container, aps-environment, remote-notification bg mode). Automatic signing + `-allowProvisioningUpdates` can mint the profile, **but the iCloud container must be created first** (human/GUI step §8). |
| Memory blow-up if gallery faults audio | Med | `externalStorage` lazy-faults; gallery reads only `waveformSamples`; assert in a test; never map `audioData` in list rows. |
| 64-cap interplay with synced capsules | Low/Med | Planner already caps + dedupes by `uuid|kind|epoch`; add the imported-capsule test (S4). |
| Two-store drift if any file-sync sneaks in | Low | One strategy only; no iCloud-Drive file sync; `audioFileName` is read-only fallback until backfilled, then unused. |

## 8. Human-in-the-loop checklist (needs Jason / Xcode GUI — like the Sentry SPM add)

- [x] **Created the CloudKit container** `iCloud.com.soundpost.Soundpost` (Developer portal, via the web UI) and **assigned it** to App ID `com.soundpost.Soundpost` (M3B2SV6M8B).
- [x] Enabled capabilities: **iCloud → CloudKit**, **Background Modes → Remote notifications**, **Push** — in code (`Soundpost/Soundpost.entitlements` + `Soundpost-Info.plist` `UIBackgroundModes`, commit `86357f2`) and on the App ID (iCloud/CloudKit + Push enabled via the ASC API).
- [x] Provisioning confirmed: created the App Store profile **"Soundpost App Store M9"** (grants `iCloud.com.soundpost.Soundpost`, `aps-environment: production`); a Release archive signs cleanly with it (`build/Soundpost.xcarchive`, entitlements verified). NOTE: `xcodebuild -allowProvisioningUpdates` could NOT authenticate with the ASC API key (works for the REST API but not the provisioning *write* path) — so provisioning was done via the REST API + the portal, and the archive uses manual signing with that profile.
- [ ] After the schema is created in Development, **promote the CloudKit schema to Production** in the CloudKit Dashboard. The Development schema (Capsule record types) is created when the app first runs CloudKit on a device/simulator **signed into iCloud** — that needs your iCloud account (couldn't be done from here).
- [ ] Two physical/simulator devices on the same iCloud account for the §S8 manual pass.
- [ ] Publish the privacy-policy update in `JasonYeYuhe/soundpost-site` (prepared on branch `m9-icloud-privacy`; merge to `main` + push when the CloudKit build ships).
- [ ] Upload a CloudKit build to TestFlight when ready (bump `CURRENT_PROJECT_VERSION` past 5 first — the in-review build is 1.1.0(5); and promote the schema to Production first or testers won't sync).

## 9. Reuse map

| Need | Source |
|---|---|
| CloudKit container + fallback ladder | `RoastMate:Shared/SharedModelContainer.swift`, `timeless:TimelessModelContainer.swift` |
| `@Attribute(.externalStorage)` blob | `ggc读书:Shared/Models/Book.swift` |
| Migration/backfill pattern (concept) | `FlowPilot:Models/ModelMigration.swift` |
| Sync reconciliation tests | `Stride:StrideTests/SyncReconcileTests.swift` — **avoid** Stride's hand-rolled `SyncService` bugs (C2/C3/C4); prefer CloudKit |
| `updatedAt` for future LWW (optional, cheap to add now) | `Stride:Shared/Habit.swift` |

## 10. Acceptance criteria (the phase is done when ALL hold)

1. Delete + reinstall on an iCloud-signed device restores **all** capsules **including audio**.
2. A second signed-in device shows the same capsules (capture-on-A → appears-on-B), and an imported
   sealed/echo capsule gets its local notification scheduled (via the import-event path, S4).
3. Signed-out / iCloud-full: app is fully functional **local-only**, no crash, honest copy, no scary alert.
4. File→Data backfill is a `@ModelActor`, idempotent, lossless, unit-tested, and **safe to run while
   CloudKit sync is active** (no main-actor violations, no empty-blob upload).
5. Backfill **deletes the source `.m4a`** after verify+save — no storage doubling.
6. Gallery scroll never faults `audioData` (verified by test); no memory regression.
7. Build warning-free; **all** existing + new tests green; i18n EN/JA/ZH-Hans 100%; zero new third-party deps.
8. PrivacyInfo / ASC label unchanged; privacy-policy prose updated; honest in-app copy updated.
9. No schema change that would block a future additive CloudKit change.

## 11. Out of scope / next

M10 = cloud-backed *delivery* (server + APNs, the seal upgrade, "cloud-backed" not "guaranteed"). M9
is *durability only*. Keep them separate: in M9 the push is nothing; in M10 the push becomes a fetch
signal whose content is restored from the iCloud store M9 builds.

## 12. Implementation status (2026-06-18)

All code-side steps implemented and committed on `master`; 79 tests / 13 suites green, build
warning-free (Debug + Release), i18n EN/JA/ZH-Hans 100% (96 keys), zero new deps.

| Step | Commit | Notes |
|---|---|---|
| S1 audioData field + dual-read playback | `4d09555` | `@Attribute(.externalStorage)`; `play(_ capsule:)` prefers data, file fallback. |
| S2 file→Data backfill (`@ModelActor`) | `de6409d` | verify-then-delete, idempotent, batched, CloudKit-safe. |
| S3 CloudKit container + fallback ladder | `489d626` | iCloud→local→in-memory; replaced only the production container site. |
| S4 reschedule on `.NSPersistentStoreRemoteChange` | `4b7e3f9` | app-layer observer, background-safe. |
| S5 CloudKit edge cases (calm state) | `60088cd` | signed-out / quota surfaced calmly; other errors logged. |
| S6 honest iCloud-state copy + privacy prose | `c906440` | footer maps off `CloudSyncMonitor.backup`; PrivacyInfo unchanged (confirmed). |
| S7 gallery memory guard test | `3a30365` | proves the @Query fetch never faults `audioData`. |
| Review fix: backfill save-failure revert | `6580db5` | adversarial review caught an orphaned-source / doubling bug on the save-failure path; fixed with a manual revert (SwiftData `rollback()` doesn't revert property updates). |
| Capability wiring + signed-out hardening | `86357f2` | entitlements (iCloud/CloudKit/aps) + `UIBackgroundModes` remote-notification; `[Float]` de-risked + signed-out detection fixed (see below). |

**Verified on a CloudKit-entitled simulator build (commit `86357f2`):**
- **`[Float]` contingency de-risked:** with the entitlement present the container still inits on the
  CloudKit rung *without throwing*, and `NSCloudKitMirroringDelegate` runs its setup assistant —
  failing only on `CKAccountStatusNoAccount`, not a schema/`[Float]` error. SwiftData's local CloudKit
  schema mapping accepts `waveformSamples: [Float] = []`. (The server-side schema push still needs a
  real iCloud account to fully confirm, but the local-mapping rejection risk is eliminated — no need to
  switch to `[Float]?` unless the entitled device build proves otherwise.)
- **Signed-out detection fixed:** the no-account condition arrives as `NSCocoaErrorDomain 134400`, not a
  bare `CKError`; `CloudSyncMonitor` now unwraps the underlying-error chain and matches that code, so a
  signed-out user gets the honest "only on this device" copy instead of "backed up to iCloud".

**Still gated on §8 (cannot be done from here):** registering the CloudKit container in the Developer
portal, the first entitled device/TestFlight archive, promoting the schema Dev→Prod, the multi-device /
delete-reinstall pass (S8), and publishing the prepared privacy prose (branch `m9-icloud-privacy` in
`JasonYeYuhe/soundpost-site`). 81 tests / 13 suites green, warning-free (Debug+Release), i18n 100%.
