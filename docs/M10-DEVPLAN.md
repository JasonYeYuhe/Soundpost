# Soundpost M10 — Cloud-backed delivery: make the seal actually arrive

> Development plan for the phase after M9. Status feeding in (2026-06-20): **M9
> (Durability) shipped** — 1.2.0 (build 6) in App Store review; CloudKit private-DB
> sync live (container + Production schema), verified on a real device. 81 tests /
> 13 suites green, warning-free, i18n EN/JA/ZH-Hans 100%, zero third-party deps
> except Sentry. **v2** — revised after a dual review (Gemini 3.5 Flash + a 5-lens
> Claude adversarial pass; the Gemini 3.1 Pro MCP was offline). The review found 5
> blockers + 27 majors; the fixes are folded in below and logged in §12. Re-review
> with Gemini 3.1 Pro before kickoff if available.

---

## 0. Goal & success statement

**Today a sealed capsule's reminder is fragile**: it fires via a *local*
`UNCalendarNotificationTrigger`, capped at **64 pending** per app, **lost on
uninstall**, delayable by reboot-before-first-unlock (PROJECT.md §1e). For a product
whose promise is *"open this in 5 years,"* that's the weakest link. M9 made the
capsule **durable**; M10 makes its far-future reminder **arrive** — a server durably
enqueues the fire date and pushes at the right time, surviving the 64-cap and (best-
effort) uninstall, with content still restored from the device's own M9 store, never
sent through APNs.

**Honest framing (DEVPLAN D2):** **"cloud-backed," not "guaranteed."** APNs is
best-effort (token churn, user-disabled notifications, multi-year horizons, a
reinstalled app that's never reopened to relink its token). The worst case stays
*"the capsule resurfaces the next time you open the app."*

**Done when:** a *far-future* capsule fires via APNs at its date after force-quit and
after delete+reinstall+reopen (manual, two devices); near-term seals stay exact via
the local path; the push is a visible, **on-device-localized** alert that deep-links
to the already-synced capsule; **exactly one** notification fires per resurfacing on
**every** device (delivery-time dedup, verified); tokens register/relink, dead tokens
prune; the backend proves caller ownership (no spoofing); signed-out/offline users
keep the local path with honest copy; the server deletes jobs/tokens on delete /
unseal / resurface / sign-out / request; PrivacyInfo + ASC label + policy update in
lockstep; build warning-free, tests green, i18n 100%, **zero new iOS deps**.

## 1. Non-negotiables

1. **Offline-first wins.** The server only enhances *far-future* delivery; it never
   gates capture, playback, seal, unseal, or echo. Signed-out / offline ⇒ the local
   path, exactly as today.
2. **Push is a signal, not the payload.** Capsule audio/note/place **never** traverse
   APNs. The push carries an `apns-collapse-id` + capsule UUID + localization keys
   only; content is read from the device's M9 store. A `assertPayloadIsClean` guard
   (allowlisting the UUID) throws before any send if content ever leaks in.
3. **On-device-localized push.** Use APNs `title-loc-key`/`loc-key` so iOS localizes
   the alert from the app's `Localizable.strings` (EN/JA/ZH stays 100%). The server
   never ships user-facing prose.
4. **Exactly one notification per resurfacing, on every device — enforced at delivery
   time, not just plan time.** Routing decides local-vs-server; an `apns-collapse-id`
   = capsule UUID + on-receipt removal of the matching local request is the *hard*
   dedup guarantee that survives every transition, multi-device, and offline-seal
   race (§4A).
5. **Proof-of-ownership auth.** A caller can only register/cancel/delete delivery for
   *its own* user — no client-asserted identity over a shared, binary-extractable
   secret (§4G).
6. **No "guaranteed."** All copy is cloud-backed/best-effort; worst case documented.
7. **Privacy/legal in lockstep.** Device token + an anonymous user key + schedule
   metadata (capsule UUID, fire date, kind) are *new collected data* → PrivacyInfo +
   ASC label + hosted policy **together**, with server-side deletion. (M9 added none.)
8. **No regression**; **zero new third-party iOS deps** (raw `UNUserNotificationCenter`
   + `registerForRemoteNotifications`, already used). Server side may use Deno std + a
   JWT/SubtleCrypto signer (no in-app dep).
9. **Monetization out of scope** — ship delivery **free**; design so an M11 entitlement
   check *could* gate it later, but add none now.

## 2. Scope

**IN:** device-token registration + a thin `PushTokenSync` (async/fallible identity
bootstrap, multi-device, relink, prune); a **Supabase** backend (project `soundpost`,
org Kanousei): `device_tokens` + `notification_jobs` (RLS), an Edge Function **due-time
poller** APNs sender (net-new state machine — not cli-pulse's immediate dispatch),
pg_cron trigger; the **delivery router** (echo→local; near seal→local; far seal +
signed-in→server) with **delivery-time dedup**; full **transition/lifecycle** handling
(sign-in/out, unseal, resurface, re-seal/edit, echo↔seal, delete); a minimal **"Delete
my cloud data"** control (required for App Review once tokens are collected); privacy
updates + server-side deletion; tests + a two-device/force-quit/reinstall pass.

**OUT (later):** monetization / Pro gating (**M11**); rich/interactive notifications,
NSE/NCE; Android/non-Apple; a full Settings screen, export, widgets (**M12**);
silent background prefetch beyond M9's `.NSPersistentStoreRemoteChange`.

## 3. Current state (grounded — cite before you change)

| Concern | Where | Note for M10 |
|---|---|---|
| Local policy | `NotificationPlanner.swift` (64-nearest, pure; `PlannedNotification`) | Reuse for echoes + **near** seals + signed-out seals; also computes the local horizon. |
| Local scheduler | `NotificationScheduler.swift` (id `capsule.<uuid>\|<kind>\|<epoch>`; `UNCalendarNotificationTrigger`) | The capsule-UUID-keyed id is the **dedup key** the push's `apns-collapse-id` must align with. |
| Coordinator | `NotificationCoordinator.swift` (`requestAuthorization`, `sync`, `didReceive`→`pendingDeepLinkCapsuleID`) | Extend: after auth `registerForRemoteNotifications`; route; on push receipt remove matching local request; `willPresent` suppress. |
| Reactive sync | `ContentView.swift` (`sealSignature` onChange → sync; `.task`/`scenePhase` → `refreshAndSync` → `refreshDueSeals` saves) | Reuse to reconcile server jobs. **Caution:** the resurface save mirrors via M9 CloudKit → other devices' `RemoteChangeReconciler` fire → keep reconcile idempotent + debounced (no upsert thrash). |
| Remote-change | `RemoteChangeReconciler.swift` (M9; `.NSPersistentStoreRemoteChange`→sync) | A seal imported on device B reconciles here; B must **not** add a local backstop for a *far* signed-in seal (dedup). |
| Sign-in state | `CloudSyncMonitor.swift` (M9; `.signedOut`/`.ok`/…) | The router's signed-in/out input. |
| Seal sheet | `SealSheet.swift` (min seal = `now + 60s`) | **Near seals can be 60s out** → must stay on the *exact* local path, never a per-minute server poll. |
| Delete | `CapsuleDetailView.delete()` calls `modelContext.delete` directly (bypasses `CapsuleStore`) + `AudioStore().delete` | Server-job cancel must hook here too (delete bypasses the reactive seal signal). |
| Identity | `CKContainer.default().userRecordID()` | **Async + fallible** (throws when signed out / pre-handshake; changes on Apple-ID switch). Not a synchronous constant — needs a pending-token cache + account-change handling. |
| Capsule | `Capsule.swift` (`sealUntil`, `sealTimeZoneID`, `echoAt`, `state`; sealed XOR echo) | Add **one** optional `serverJobSyncedAt: Date?` (additive, CloudKit-legal) to coordinate cross-device backstop removal (§4A/D). |
| Entitlements | `Soundpost.entitlements` (`aps-environment = development`), `Soundpost-Info.plist` (`UIBackgroundModes: remote-notification`) | Present (M9 §8). **The resolved dev/prod value is NOT readable at runtime** → pick environment via `#if DEBUG` (§4F). |
| App entry | `SoundpostApp.swift` | Add `@UIApplicationDelegateAdaptor` for `didRegister…DeviceToken` + `didFailToRegister`; wire `PushTokenSync`. |

## 4. Architecture decisions (the hard parts)

**A. Delivery model — local for near & exact, server for far & durable, with
delivery-time dedup as the hard guarantee.** (This is the central decision; the v1
"signed-in seal ⇒ server-only, suppress local" was wrong — see §12.)

Routing (recomputed on launch + every reactive sync):
- **Echo** → **local** always (near-term, offline; existing path).
- **Seal within the local horizon H** (fire date inside the nearest-64 window the
  planner reliably covers; includes `now+60s` seals) → **local** (exact, offline).
- **Seal beyond H + signed in** → **server** (durable far-future + uninstall
  insurance).
- **Seal beyond H + signed out** → **local** (best-effort fallback) + honest copy.

**Delivery-time dedup (mandatory, the real guarantee):** the server push sets
`apns-collapse-id = <capsuleUUID>` and carries the UUID; on receipt
(`didReceiveRemoteNotification` / `willPresent`) the app **removes any pending or
delivered local `capsule.<uuid>|seal|*` request** and suppresses a local seal whose
push already arrived. Every device does this. So even during a transition, a
horizon-crossing, an offline-seal backstop, or a multi-device window where *both* a
local request and a server push momentarily exist, the user sees **one**
notification. `serverJobSyncedAt` (set when the server confirms the job, synced via
M9 CloudKit) lets all devices drop their local backstop once the server owns it.

**Transitions (must be specified + tested):**
- *Sign-out:* prune **only this device's token** — **jobs are user-scoped (shared
  across the user's devices) and must NOT be deleted on a single device's sign-out**,
  or the user's other signed-in devices stop receiving the push. Re-arm the **local**
  notification on *this* device for in-horizon seals (best-effort, it's now local-only);
  far seals fall back to "resurfaces on next open." Jobs are removed only by capsule
  delete / unseal / resurface / "Delete my cloud data" (below), never by sign-out.
- *Sign-in:* register far seals server-side; dedup any local backstop.
- *Unseal / delete:* cancel the server job + remove the local request.
- *Resurface* (`refreshDueSeals` flips `.sealed`→`.resurfaced`): **cancel the server
  job** (it's no longer in the desired set) so no push fires after the in-app
  resurface; idempotent + debounced to avoid CloudKit-save thrash.
- *Re-seal / edit date:* the job upsert updates `fire_at` **and** resets `status` to
  `pending` (a changed `fire_at` re-arms; an unchanged one must **not** resurrect a
  `sent` job — see §4E).
- *Echo→seal supersede:* remove the echo's local request; register the seal per the
  routing above.

**B. Identity = a per-user secret in the M9 CloudKit private DB (proof-of-ownership).**
On first launch generate a high-entropy random `deliveryUserKey`; store it in the
CloudKit **private** database so it syncs only to *this user's* devices (and survives
reinstall on a signed-in device). It is both the server **user key** (the fan-out
group) and the **bearer** the app presents to the backend — because only the user's
own devices possess it, no caller can spoof another user's delivery. Resolution is
**async/fallible** (CloudKit fetch): use the pending-token cache pattern
(`cli pulse:…/DataRefreshManager.syncPushToken`) — stash the APNs token until the key
is available, then upsert; re-key + migrate on Apple-ID switch; signed-out ⇒ no key ⇒
local path. (Alternative considered: Supabase anonymous-auth + `auth.uid()` RLS — also
valid; the CloudKit-secret reuses M9, needs no anon-auth surface, and groups a user's
devices/reinstalls cleanly. Pick one in S1; do **not** ship the v1 "client-asserted
userRecordID over a shared key" — it has no ownership proof.)

**C. Push = visible alert, on-device-localized, content-free, collapsible.** The Edge
Function sends `aps.alert` with `title-loc-key`/`loc-key` (resolved on-device from
`Localizable.strings`, so JA/ZH stay localized), `apns-collapse-id = <uuid>`,
`apns-push-type: alert`, a long `apns-expiration` (let APNs retry across an offline
window), and the capsule UUID for the existing tap→deep-link path. The only per-job
data stored/sent: user key, capsule UUID, fire instant, IANA tz, kind. No
note/place/audio, ever; `assertPayloadIsClean` (ported from cli pulse, UUID
allowlisted) is the belt.

**D. Server owns job state; one local flag for cross-device coordination.** Reconcile
the desired far-seal job set against Supabase (upsert new / cancel removed), mirroring
`NotificationScheduler`'s diff. Add the single `serverJobSyncedAt` flag (§3) so a
device that imported a seal can drop its local backstop once another device confirmed
the server job.

**E. Server = a far-future due-time poller (NET-NEW; the cli-pulse SQL is immediate-
dispatch — reuse only its JWT signer / HTTP-2 dispatch / 410-prune).** Supabase
`soundpost` (org Kanousei, Pro paid):
- `device_tokens(user_key text, token text unique, environment text, platform default 'ios', updated_at)`; `ON CONFLICT(token) DO UPDATE` transfers ownership across Apple-ID switches (cli-pulse pattern).
- `notification_jobs(id uuid pk, user_key text, capsule_id text, kind text, wall_clock timestamp, time_zone text, status text default 'pending', attempts int default 0, next_attempt_at timestamptz, locked_at timestamptz, last_error, created_at, updated_at)`; **unique `(user_key, capsule_id)`**.
- **DST-correct firing:** store `wall_clock` (no tz) + `time_zone`; the poller claims
  `WHERE status='pending' AND next_attempt_at <= now() AND (wall_clock AT TIME ZONE time_zone) <= now()` — so a years-out seal fires at the intended wall-clock even if tz law changes (matches PROJECT.md §1e.5).
- Edge Function `send-due-notifications` (cron-invoked): claim due rows `FOR UPDATE
  SKIP LOCKED`, set `locked_at`; resolve the user's tokens; build one cached ES256
  APNs JWT (kid `2R9PCC63MF`, iss `KHMK6Q3L3K`); POST HTTP/2 to **per-token** host
  (`api.push.apple.com` for `environment='production'`, `api.sandbox.push.apple.com`
  for `'development'`) with `apns-topic: com.soundpost.Soundpost`; on success
  `status='sent'`; on `410`/BadDeviceToken delete the token; on transient error
  increment `attempts`, set `next_attempt_at = now()+backoff(attempts)`, dead-letter
  after N (terminal `status='failed'`).
- **Idempotent upsert preserving `sent`:** the app's reconcile upsert must `ON
  CONFLICT (user_key,capsule_id)` update `wall_clock/time_zone` and only reset
  `status='pending'` **when `wall_clock` actually changed** — never resurrect a `sent`
  row (else launch-time re-upserts re-fire past pushes).
- **pg_cron** every minute → `pg_net`/`http` POST the function with a timing-safe
  shared secret **distinct from the service-role key** (Kanousei pattern). Up-to-60s
  delivery latency is acceptable for far-future seals (state it).

**F. Token lifecycle + environment.** Register `registerForRemoteNotifications()`
after permission is granted **and** on every launch (token reconciliation; cli-pulse
pattern), plus `didFailToRegister` (log INFO, fall back to local). `environment` =
**`#if DEBUG` ⇒ `development` else `production`** (the entitlement's resolved value is
not readable at runtime; TestFlight + App Store builds are Release ⇒ production; Xcode
debug ⇒ development). Relink on token churn + sign-in; `410` + a staleness sweep
prune. **Honest reinstall caveat:** survival-after-reinstall requires the app to be
**reopened** (to relink the new token) before `fire_at`; a never-reopened reinstall or
a years-stale token may not deliver — that's the "best-effort," with the in-app
resurface as backstop.

**G. Backend auth.** App → a single Edge Function (`sync-delivery`) for
register-token / upsert-job / cancel-job / delete-all, authenticated by the per-user
CloudKit secret (§B) — the function trusts it as the user key because only the user's
devices hold it. Tables: RLS **deny all to anon**; only the function (service role)
writes. The cron→`send-due-notifications` call uses a separate timing-safe secret +
an allowed-trigger header (cli-pulse `auth.ts` pattern). The `.p8` + service-role key
live **only** in the function env, never in the app. Rate-limit per user key. (If
Supabase anon-auth is chosen instead, gate every write on `auth.uid()` with the user
key as a secondary fan-out column.)

## 5. Work breakdown (sequenced; each step compiles + commits)

**S1 — Token registration + identity bootstrap (client; no server yet).**
`@UIApplicationDelegateAdaptor` AppDelegate: `didRegister…DeviceToken` (→ hex),
`didFailToRegister` (INFO). `PushTokenSync` behind a `DeliveryBackend` protocol (mock
for tests). Async/fallible `deliveryUserKey` bootstrap (CloudKit secret) + **pending-
token cache** (replay after the key resolves / after sign-in). Environment via
`#if DEBUG`. *Verify:* token→hex; env selection; key-unavailable caches then replays;
one upsert per (key, token); warning-free.

**S2 — Supabase backend (NET-NEW poller).** Project `soundpost`; tables + RLS (§E);
`send-due-notifications` (claim-due `FOR UPDATE SKIP LOCKED`, per-token host, ES256
JWT cache, 410-prune, backoff + dead-letter, content-free loc-key payload +
`assertPayloadIsClean`); `sync-delivery` write function (§G); pg_cron + timing-safe
secret. *Verify:* a seeded far-future job fires to a real dev token at its wall-clock;
a bad token prunes; concurrent runs don't double-send; a re-run does **not** re-fire a
`sent` job. Reuse: `cli pulse:…/send-approval-push` (JWT/HTTP-2/410 **only**),
`Kanousei` (cron secret). **Human-gated (§8).**

**S3 — Delivery router + `SealDeliveryService` + delivery-time dedup.** Compute the
horizon split (§4A); echoes + near + signed-out seals → local (unchanged); far
signed-in seals → server (reconcile upsert/cancel). On push receipt, remove the
matching local `capsule.<uuid>|seal|*` + `willPresent`-suppress; set/read
`serverJobSyncedAt`. *Verify (unit):* far signed-in seal ⇒ server upsert + no local;
near seal ⇒ local + no server; echo ⇒ local; unseal/delete ⇒ cancel; a simulated push
receipt removes the matching local request; idempotent re-sync.

**S4 — Transitions + lifecycle + deletion routing.** Implement every §4A transition
(sign-in/out, unseal, resurface→cancel job, re-seal/edit→re-arm, echo↔seal, delete via
a path that cancels the job — fix `CapsuleDetailView.delete` bypass). Sign-out re-arms
local before pruning. *Verify:* each transition fires exactly once / cancels correctly;
no orphaned far seal on sign-out; resurface cancels the job.

**S5 — Privacy / legal (lockstep) + "Delete my cloud data".** PrivacyInfo: **Device
ID** (APNs token) + the anonymous **user key** (an *Identifier* — declare it; the
review flagged it's a User-ID-class id, not just a device id) under *App
Functionality*, tracking=false, not-linked-for-tracking; consider *Other Usage Data*
for the schedule metadata. Update the ASC nutrition label to match. Add a minimal
**"Delete my cloud data"** action (deletes tokens+jobs) — required once tokens are
collected. Publish the policy update (`JasonYeYuhe/soundpost-site`). **Ship the
deletion path + policy BEFORE/with the label** (sequencing). Re-confirm no Required-
Reason API additions.

**S6 — Tests + on-device acceptance.** Unit: router/horizon split, dedup (push receipt
removes local), token plumbing, job-reconcile diff (incl. `sent`-preserve), transitions,
planner-still-correct-for-echoes. Server: poller idempotency + 410 prune + backoff (a
tiny harness). Manual (two iCloud devices): far seal → fires on A **and** B at its
date, **each exactly once** (not local + push); force-quit → still fires; delete +
reinstall + **reopen** on A → relinks → fires; near seal (now+2min) → exact local fire;
JA/ZH device → push is localized; sign-out → local path, no orphan; airplane mode at
fire → arrives later / in-app resurface. Record in DEVPLAN.md.

## 6. Privacy / legal delta

First milestone collecting data off-device: **APNs device token** (Device ID) + an
**anonymous per-user key** (an Identifier — treat as User-ID-class, not merely a
device id) + minimal **schedule metadata** (capsule UUID, wall-clock + tz, kind).
- **PrivacyInfo.xcprivacy** — `NSPrivacyCollectedDataTypeDeviceID` (App Functionality;
  linked=false; tracking=false); declare the user key as an identifier; consider
  *Other Usage/User Data* for the schedule metadata. No new Required-Reason API.
- **ASC nutrition label** — Identifiers (Device ID + the user key), App Functionality,
  not tracking, not linked to identity; tracking=false is valid **only** because the
  ids are never combined with other-app/data-broker data (state + enforce).
- **Hosted policy** — what the token/key/schedule rows are, that they enable reminder
  delivery, that the server **never** receives capsule content, retention, and
  deletion (capsule delete / unseal / **resurface** / sign-out / "Delete my cloud
  data"). Reuse the M9 policy-update flow.
- **Server-side deletion** is a hard requirement and must cover the **resurface**
  transition (the dominant lifecycle event), not just delete/unseal/sign-out.

## 7. Risks & mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| **Double-fire** (local + push; multi-device; transitions) | High | Delivery-time dedup: `apns-collapse-id`=UUID + on-receipt removal of `capsule.<uuid>\|seal\|*` + `willPresent` suppress, on every device; `serverJobSyncedAt` drops backstops. Not plan-time-only. |
| **Auth spoofing** (forge another user's delivery) | High | Per-user CloudKit secret as bearer/key (only the user's devices hold it); RLS deny-anon; service-role only via function; cron secret ≠ service-role. |
| **Reconcile re-fire** (`sent` job reset → re-push) | High | Upsert resets `status` only when `wall_clock` changed; never resurrect `sent`. |
| **Near-term seal late/missed** (now+60s via per-min cron) | High | Near seals (within H) stay on the **exact local** path; only far seals go server-side. |
| **Far-future DST law change** | High | Store `wall_clock`+tz; poller evaluates `wall_clock AT TIME ZONE tz <= now()`. |
| **APNs env mismatch** (dev token → prod host) | High | `#if DEBUG` env per token; per-token host in the function; TestFlight/App Store=prod. |
| **Sign-out orphans a far seal / breaks other devices** | Med | Sign-out prunes **only this device's token**, never the user-scoped jobs (other devices keep delivering); re-arm local (in-horizon) on this device; far seals fall back to in-app resurface. |
| **Async/fallible userRecordID/secret at token time** | Med | Pending-token cache + replay; account-switch re-key; signed-out ⇒ local. |
| **Reuse mis-scope** (copy cli-pulse immediate dispatch) | Med | Reuse JWT/HTTP-2/410 only; the due-time claim/lock/backoff state machine is net-new. |
| **Cron double-send** | Med | `FOR UPDATE SKIP LOCKED` + `locked_at` reclaim + unique `(user_key,capsule_id)` + idempotent. |
| **Stale token after long uninstall** | Low/Med | Relink on reopen; honest "reopen before fire / best-effort" copy + in-app resurface backstop. |
| **CloudKit-save thrash** (resurface mirror → reconcilers) | Low/Med | Idempotent + debounced reconcile; no-op when the desired set is unchanged. |
| **Privacy label drift** | High | PrivacyInfo + label + policy + deletion (incl. resurface) shipped together (S5). |

## 8. Human-in-the-loop checklist (needs Jason)

- [ ] Create Supabase project `soundpost` (org Kanousei; Pro paid); capture URL + keys.
- [ ] Function env secrets only: APNs `.p8` (`~/Documents/secrets/AuthKey_2R9PCC63MF.p8`, kid `2R9PCC63MF`), team `KHMK6Q3L3K`, bundle `com.soundpost.Soundpost`, Supabase service-role key, and a **separate** cron secret. Never in the binary.
- [ ] Enable `pg_cron` + `pg_net`/`http`; schedule the minute trigger.
- [ ] Confirm the APNs key is enabled for the team/bundle; confirm `apns-topic` stays in sync with the bundle id.
- [ ] Decide the auth model (CloudKit-secret vs Supabase anon-auth) in S1.
- [ ] Update the ASC privacy nutrition label (Identifiers: Device ID + user key, App Functionality).
- [ ] Publish the policy update in `JasonYeYuhe/soundpost-site` (ship before/with the label).
- [ ] Two iCloud devices for the §S6 manual pass (far-seal arrive once on both, force-quit, delete+reinstall+reopen, near-seal exact, JA/ZH localized, signed-out, airplane mode).

## 9. Reuse map

> TokyoHelp's source is **gone locally**; `cli pulse` is the in-repo equivalent. **Adapt,
> don't copy:** cli-pulse's backend is *immediate-dispatch* (AFTER-INSERT trigger +
> cron-as-retry) — M10 needs a *far-future due-time poller*. Reuse the JWT signer,
> HTTP/2 dispatch, and 410-prune; the claim/lock/backoff queue logic is **net-new**.

| Need | Source |
|---|---|
| APNs token register / relink (client) | `cli pulse:CLI Pulse Bar iOS/iOSAppDelegate.swift` (`@UIApplicationDelegateAdaptor`, register-on-launch, `didFailToRegister`), `CLIPulseCore/PushTokenSync.swift` (`Data`→hex, validation), `CLIPulseCore/DataRefreshManager.swift` (`syncPushToken` idempotent upsert + **pending-token cache** + logout unregister) |
| APNs sender bits (ES256 JWT + HTTP/2 + 410-prune + clean-payload guard) — **bits only** | `cli pulse:backend/supabase/functions/send-approval-push/` (`index.ts` SubtleCrypto JWT + 55-min cache + `…/3/device/<token>` dispatch + `410`→delete; `auth.ts` internal-call gate; `assertPayloadIsClean`) |
| Token/job tables + RLS + `ON CONFLICT(token)` transfer | `cli pulse:backend/supabase/migrate_v0.32_remote_approvals_push.sql` (tables/RPCs/RLS) — **note its dispatch model is the wrong one; take the schema/auth shapes** |
| Cron timing-safe secret | `Kanousei:src/app/api/cron/*` (`timingSafeEqual(sha256(token), sha256(secret))`) |
| Apple JWT (ES256, .p8) shape | `ColorArchive:server/apple-jws.js`; SubtleCrypto signer above |
| Diff-against-plan reconcile / sign-in routing / tap→deep-link | in-repo: `NotificationScheduler.swift`, `CloudSyncMonitor.swift`, `NotificationCoordinator.swift` |
| Sync reconcile tests | `Stride:StrideTests/SyncReconcileTests.swift` |

## 10. Acceptance criteria

1. A *far-future* seal fires a **visible, on-device-localized** push at its wall-clock
   on a signed-in device, after force-quit and after delete+reinstall+**reopen** — two-
   device manual pass.
2. **Exactly one** notification per resurfacing on **every** device (no local+push
   double), verified across an offline-seal backstop, a sign-in/out transition, and
   the 2nd-device import. Near-term seals fire **exactly** via the local path.
3. The push deep-links to the capsule; **no capsule content** traverses APNs
   (`assertPayloadIsClean` enforced); JA/ZH alerts are localized.
4. The backend rejects a caller that can't prove ownership of a user key; tokens
   register/relink; `410` prunes; delete / unseal / **resurface** / sign-out / "Delete
   my cloud data" remove the server job/token.
5. Signed-out / denied / offline: fully functional local + in-app path, honest copy.
6. PrivacyInfo + ASC label + policy in lockstep (deletion + policy live with/before the
   label); server-side deletion incl. resurface; no new Required-Reason API.
7. Warning-free; all tests green; i18n 100%; **zero new third-party iOS deps**.
8. Smallest honest surface (2 tables, send + sync functions, cron) on paid Supabase Pro;
   `.p8` + service-role only server-side; reconcile is idempotent (no re-fire of `sent`).

## 11. Out of scope / next

**M11 = Monetization** (StoreKit 2 Pro; may gate this delivery — design allows an
entitlement check but M10 ships it free). **M12 = UX polish** (full Settings incl. an
iCloud/delivery toggle + the broader "delete my data," widgets, export). Keep M10 to
*delivery*: durable store = M9; reliable far-future reminder = M10; paying for richness
= M11.

## 12. Review log (v1 → v2)

Dual review (Gemini 3.5 Flash via Antigravity + a 5-lens Claude adversarial workflow;
the Gemini 3.1 Pro MCP was offline). 5 blockers + 27 majors; folded in:
- **Auth had no proof-of-ownership** (client-asserted `userRecordID` over a binary-
  embedded shared key was spoofable; the cli-pulse reuse only worked on a real
  `auth.uid()` session). → per-user CloudKit secret as bearer/key (§B/§G). **(P0, both)**
- **Double-fire was prevented only at plan time** (the lost-reminder backstop + multi-
  device + transitions create real overlap; no delivery-time dedup). → mandatory
  `apns-collapse-id` + on-receipt local-removal + `serverJobSyncedAt` (§A/§4). **(P0, Claude×3)**
- **Reconcile re-fired `sent` jobs** on every launch upsert. → reset `status` only on a
  changed `wall_clock` (§E). **(P0, Gemini)**
- **Near-term seals (now+60s) routed to a per-minute server lost exactness.** → near
  seals stay on the exact local path; only far seals go server-side (§A). **(P0, Claude)**
- **Reuse mis-scoped** (cli-pulse is immediate-dispatch; M10 needs a far-future
  poller). → reuse JWT/HTTP-2/410 only; queue state machine is net-new (§E/§9). **(P1, both)**
- **Far-future DST law change** (fixed `timestamptz` fires at wrong wall-clock). → store
  `wall_clock`+tz, evaluate in tz (§E). **(P1, Gemini)**
- **`userRecordID`/secret is async/fallible + changes on Apple-ID switch.** → pending-
  token cache + account re-key (§B/§F). **(P1, both)**
- **APNs dev/prod environment isn't runtime-readable.** → `#if DEBUG` rule + per-token
  host (§F). **(P1, both)**
- **Push couldn't be localized server-side** (JA/ZH regression). → APNs loc-keys (§C). **(P1, Claude)**
- **Server-side deletion + lifecycle missed the `.resurfaced` transition**, the
  delete-bypasses-`CapsuleStore` path, and sign-out orphaning. → §A transitions + §S4 +
  §6. **(P1, both)**
- **Privacy label under-declared** (the user key is a User-ID-class identifier; schedule
  metadata is usage data). → §6. **(P2, both)**
- Minors: `apns-expiration`/`priority`/`collapse-id`; retry backoff + terminal rule;
  `assertPayloadIsClean` must allowlist the UUID; a minimal "Delete my cloud data" entry
  for App Review; ship deletion+policy before the label. → folded into §C/§E/§S5.

## 13. Implementation status (2026-06-20)

All code-side steps **implemented + committed on `master`**, each compiling and
passing tests before the next (per the plan). **116 Swift tests / 17 suites +
18 Deno tests green**; warning-free **Debug + Release**; i18n **EN/JA/ZH-Hans 100%**
(107 keys); **zero new third-party iOS deps** (raw `UNUserNotificationCenter` +
`registerForRemoteNotifications`; server uses Deno std + SubtleCrypto). Each step
was dual-reviewed by a multi-lens adversarial workflow before commit; confirmed
findings folded in (S1: 4, S2: 8, S3: 1, S4+S5: 5 — see the per-step commits + the
review-fixes commit).

| Step | Commit | What landed | Review findings folded |
|---|---|---|---|
| S1 token reg + identity | `0789aaa` | AppDelegate adaptor; `PushTokenSync`; `DeliveryEnvironment` (#if DEBUG); `DeliveryBackend` (stub); `CloudKitDeliveryIdentity` (per-user private-DB secret); `DeliveryRegistrar` (pending cache, dedup, relink, prune) | 4 (actor-reentrancy coalescing, account-bound cache, reentrancy-safe flush claim, malformed-record self-heal) |
| S2 backend (poller) | `3b5c1f8` | `device_tokens`+`notification_jobs`+RLS+RPCs; `send-due-notifications` (claim-lock, per-token host, ES256 JWT cache, 410-prune, backoff+dead-letter, content-free loc-key payload + `assertPayloadIsClean`); `sync-delivery`; pg_cron; runbook | 8 (poison-tz head-of-line block + throw-proof `is_job_due`; 10s fetch timeout + lease sizing; token-read-error mislabel; settle-RPC error checks; labelled `mark_job_deferred`; `kind` whitelist; KvU64 rate-limit) |
| S3 router + dedup | `18d1105` | `Capsule.serverJobSyncedAt`; `SealDeliveryRouter` (near→local/far→server, 24h horizon); `SealDeliveryService` (idempotent+debounced reconcile); planner backstop-drop; on-receipt dedup (`apns-collapse-id` + local-request removal); `SupabaseDeliveryBackend`; push loc-keys | 1 (reconcile upsert/cancel reentrancy race → claim-before-await) |
| S4 transitions | `400bc49` | delete→cancel-job (bypass fix); unseal/resurface/re-seal via reconcile; `DeliveryAccountObserver` (sign-in/out/switch); `lastUserKey` for prune-after-signout | — |
| S5 privacy + delete | `464d855` | PrivacyInfo (Device ID + User ID + Other Data, App Functionality/not-linked/not-tracking); "Delete my cloud data" control + opt-out gate; policy-delta draft | — |
| S6 tests + acceptance | _this commit_ | `apns_test.ts` (per-token host); status record | — |
| S4+S5 review fixes | _this commit_ | account-scoped opt-out **tombstone** (`delivery_optouts`) so "Delete my cloud data" sticks across devices; latch opt-out only on a confirmed purge (+ failure alert); durable delete-path job cancel (survives cold launch / unresolved key); `CKAccountChanged` burst coalescing | 5 (the two "doesn't stick" majors, the offline-purge-lies major, the orphan-on-unresolved-key minor, the coalescing nit) |

**Auth-model decision (the §8 open item):** chose the plan's recommendation —
the **per-user CloudKit private-DB secret** as both fan-out key and proof-of-
ownership bearer (not Supabase anon-auth). Reuses M9, no anon-auth surface,
groups a user's devices/reinstalls cleanly. Swappable behind `DeliveryBackend` /
`DeliveryIdentityProviding` if Jason prefers otherwise.

**Backend DEPLOYED (2026-06-20) — co-located in `cli-pulse` (decision: §below).**
Rather than a new paid project, the backend was **co-located in the existing
`cli-pulse` Supabase project** (org Kanousei, already Pro) at **$0 extra** — its
`pg_cron`/`pg_net`/Vault/APNs were already enabled, and the tables are namespaced
(no collision). Driven via the Supabase MCP:
- Applied migrations: tables + RLS + RPCs + the `delivery_optouts` tombstone +
  anon/authenticated revokes (clears advisor 0026/0027) + `read_m10_secret` (the
  service-role PostgREST client can't reach the `vault` schema directly) + the
  pg_cron minute trigger.
- Reused cli-pulse's **team-`KHMK6Q3L3K` APNs key** already in Vault (same Apple
  team, so it signs `com.soundpost.Soundpost`); set `m10_cron_secret`
  (server-generated) + `m10_app_url` in Vault. The functions read secrets from
  Vault (env fallback retained for a future dedicated-project move).
- Deployed `sync-delivery` + `send-due-notifications` (both `verify_jwt=false`,
  own auth). Smoke-tested end-to-end: register/upsert/cancel via the live
  function; bad-key→401; cron-secret gate (missing/bad auth); the **per-minute
  cron returns `200 {"claimed:0}`** (reads secrets, claims due jobs). Test rows
  cleaned. Client config wired (`SupabaseDeliveryConfig.current`).

**Uploaded to App Store Connect (2026-06-20): 1.3.0 (build 7).** Bumped 1.2.0→1.3.0
/ build 6→7; archived (Release, device, automatic signing) + uploaded via the ASC
API key (`scripts/build-upload-asc.sh`). `ARCHIVE/EXPORT SUCCEEDED`, `Upload
succeeded` → TestFlight processing. (Only warning: the known Sentry-dSYM non-blocker
from M8 — the app's own dSYM uploads fine.)

**Still human-gated:**
1. **ASC App Privacy nutrition label** + **publish the policy delta**
   (`docs/M10-privacy-policy-delta.md` → `JasonYeYuhe/soundpost-site`), shipped
   with/before the label.
2. **The two-device manual acceptance pass** (§S6): a far seal needs a Release/
   TestFlight build (prod APNs) signed-in on two iCloud devices — fires once on A
   *and* B at its date; force-quit; delete+reinstall+reopen on A; near seal exact
   local; JA/ZH push localized; signed-out local path; airplane-mode-at-fire
   arrives later / in-app resurface. Record here when done.
   - Note: an Xcode **Debug** build registers a **development** (sandbox) APNs
     token; the poller routes it to the sandbox host automatically (per-token), so
     dev-build testing works too — but App Store delivery is the Release/prod path.
