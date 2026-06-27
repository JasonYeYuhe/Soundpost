# Soundpost M12 — Make the resurface moment land (+ browsability, Settings, hardening)

> Development plan for the phase after M11. Status feeding in (2026-06-27): **M11
> (Monetization) SHIPPED to the binary** — 1.4.0 (build 8) uploaded to App Store
> Connect (VALID, TestFlight processing); both Pro products created in ASC
> (annual `com.soundpost.Soundpost.pro.annual` + lifetime
> `com.soundpost.Soundpost.pro.lifetime`, no monthly). 1.3.0 (build 7, M9 iCloud
> durability + M10 cloud-backed delivery) is still in App Review. The live App
> Store version is **1.1.0**. ~5,200 LOC Swift, 150 tests / 23 suites green,
> warning-free, i18n EN/JA/ZH-Hans 100%, zero third-party deps beyond Sentry.
>
> Refines DEVPLAN.md §M12 ("UX & feature polish") + §Mx (engineering hardening)
> into implementation-ready steps. **Hardened by a multi-lens audit** (4 product/UX
> + 2 code/engineering lenses) and a Codex review pass; findings folded in.

---

## 0. Goal & success statement

M11 made Soundpost *sellable*. M12 makes it **felt**. The product's entire thesis
(PROJECT.md §1c) is *capture how a moment sounds → seal it → your future self opens
it like a postcard*. Today the **payoff half is unbuilt**: a resurfaced capsule
opens as an ordinary detail screen, the notification is generic, and a seal can
fire at 2:47 AM. M12's headline is to **make the resurface moment land** — the one
change most likely to create the "wow" that drives word-of-mouth (and, ethically
timed, ratings). Around it: make the accumulating archive **browsable**, give the
app a calm **Settings** home (with bulk *export-your-data*), surface **anticipation**
("next to resurface"), and pay down the **hardening** debt the audit surfaced
(seal-hour bug, dSYM upload, an observer leak, missing durability tests, no CI).

**Everything in M12 is FREE-TIER.** Pro stays exactly as M11 shipped — additive
creation richness (export/share, 5-min clips, theme pack). We never charge to
receive, browse, reveal, export, or be reminded of a memory.

**Done when:** opening a due seal is a deliberate, quiet "then-vs-now" reveal at a
humane hour with personalized (privacy-safe) lead-in copy; the gallery is
searchable + filterable + date-sectioned; a calm Settings screen hosts privacy/
support, notification + iCloud state, "Delete my cloud data", and a bulk
export-your-data; an in-app "next to resurface" strip shows anticipation; a
milestone review prompt fires only after a genuine resurface; the audit's must-fix
issues are closed; build warning-free, all tests green, i18n EN/JA/ZH-Hans 100%,
**zero new third-party deps** (WidgetKit/StoreKit/AVFoundation/CloudKit are all
first-party); crashes are symbolicated; CI guards the standing bars.

## 1. Non-negotiables (carried from PROJECT.md / DEVPLAN.md / M9–M11)

1. **Never charge to receive a memory.** No paywall on seal, resurface, the reveal,
   browse/search, export-your-data, notifications, the upcoming strip, or playback.
   Pro stays additive creation richness only (M11 §2A).
2. **Lapse is harmless / honest limits stand.** The seal is a gentle, honor-system
   lock; delivery is best-effort (cloud-backed, not "guaranteed"); we never fake a
   time-lock. M12 copy keeps that honesty (PROJECT.md §1e).
3. **Calm, no dark patterns.** The reveal is quiet, tasteful, and fully
   Reduce-Motion-skippable — no melodrama, no "share to continue" gate. Settings +
   filters stay secondary chrome, not engagement surfaces. The review prompt fires
   on a genuine positive moment, capped per version, never on launch/mid-capture.
4. **Privacy-first.** No tracking/analytics (only Sentry crash). Personalized
   notification copy is the user's own private words → it shows on the lock screen,
   so it is gated behind a preference with a **conservative default** (§4A). Bulk
   export is an export-*your*-data affordance; nothing new leaves the device.
5. **Offline-first, no backend churn.** M10's delivery backend is untouched; the
   reveal/browse/Settings/export are 100% on-device. Personalizing the **local**
   notification changes no privacy posture (it never traverses the server; the
   server push stays content-free).
6. **No regression / standing bars:** warning-free build, ALL tests green, i18n
   EN/JA/ZH-Hans 100%, **zero new third-party deps**. Each step (S1→S8) compiles +
   passes tests + is COMMITTED before the next, with `Co-Authored-By:` trailer.

## 2. Scope

**IN:** (a) resurface-time normalization (the seal-hour fix); (b) personalized,
privacy-safe resurface/echo notification copy + a lock-screen-preview preference;
(c) a dedicated resurface **reveal**; (d) a milestone **review prompt**; (e) gallery
**browsability** (search + mood/sealed filter + date sectioning); (f) a calm
**Settings** screen incl. bulk **export-your-data**; (g) an in-app **"next to
resurface"** strip; (h) **hardening & release-ops** (observer-leak deinit pass +
durability tests, reinstall re-registration test, restore-error surfacing, os.Logger
on the durability paths, `.storekit` price sync, a VoiceOver + Dynamic Type pass,
**dSYM upload**, **CI**, a Swift 6 strict-concurrency trial).

**OUT (later / explicitly deferred — see §11):** animated-waveform **video** export
(its own focused milestone — risky AVAssetWriter work); multi-capsule export;
custom mood color / custom echo window (additive Pro micro-levers); promo / offer +
win-back codes; a **committed WidgetKit target** (in-app upcoming strip is M12's
committed version; the home-screen widget is an explicit stretch); in-app language
override (the app already follows the system language with i18n 100% — settings-bloat
for "minimal surface", deferred unless Jason wants it).

### 2A. The headline + themes

**Headline theme:** *the resurface moment*. The four product lenses converged on two
high-value themes — the **resurface reveal** and **gallery browsability**. The reveal
is the more product-defining (it's the emotional core no competitor builds, and the
precondition for an ethically-timed review prompt), so it leads; **browsability** is
the strong #2 and ships right after. Three themes, sequenced:

- **Foundation (S1):** release-ops first — dSYM upload + CI + the i18n cleanup — so
  every M12 change is symbolicated and CI-gated.
- **A · The moment (S2–S5):** humane fire time → personalized copy → the reveal → the
  review prompt. Each step compounds the one before.
- **B · The archive & home (S6–S7):** browsability → Settings (+ export-your-data).
- **C · Strip + hardening (S8):** the upcoming strip + the audit's correctness/test/
  observability debt.

## 3. Current state (grounded — cite before you change)

| Concern | Where | Note for M12 |
|---|---|---|
| **Seal/echo fire time** | `Views/SealSheet.swift` (DatePicker `.date`-only), `Capture/CaptureView.swift` echoPicker (`.date`-only) → `Services/CapsuleStore.swift` `seal(until:)` / `setEcho`; `Models/Capsule.swift` `sealUntil`/`echoAt` | **HIGH bug:** date-only picker preserves the *capture* time-of-day, so a seal/echo fires at an arbitrary, often antisocial hour. Normalize to a humane local hour (§4B/S2). |
| Resurface presentation | `Views/CapsuleDetailView.swift` `markOpenedIfResurfaced` (silent state flip on appear), `ContentView.swift` `handleDeepLink` (plain nav push) | Replace the silent path with the dedicated reveal (§4C/S4). No `sealedAt` field exists; `createdAt` is the honest elapsed-time proxy. |
| Notification copy | `Services/NotificationCoordinator.swift` `sync(capsules:)` content closure (generic "A capsule has resurfaced") | The closure already gets a `createdAt` map; widen it to carry the capsule's own note/place/mood (§4A/S3). |
| Gallery | `ContentView.swift` (one `@Query(sort:\.createdAt,.reverse)` → flat `LazyVStack`), `Views/CapsuleCard.swift` | No search/filter/sort/grouping. Add browsability (§4D/S6) — **metadata-only**, never fault `audioData` (the M9 gallery-memory rule; reuse the `storageString` discipline). |
| Chrome / Settings | `ContentView.swift` (only the Pro toolbar item + `storageFooter`); "Delete my cloud data" stranded in the footer; privacy/policy reachable only inside the paywall | Add a calm Settings screen (§4E/S7); move cloud controls there; the Pro entry's `person.crop.circle` reads as "account" — relabel here. |
| Anticipation | none (no WidgetKit/ActivityKit target); `Services/NotificationPlanner.swift` already computes the nearest-due set | Add an in-app "Upcoming" strip (§4F/S8); the planner's set is the data source. |
| Review prompt | none (no `requestReview`/`SKStoreReview` anywhere) | Add `RequestReviewAction` after the reveal (§4G/S5). Reuse `ggc读书:ReviewManager.swift`. |
| AudioRecorder lifecycle | `Audio/AudioRecorder.swift` (registers 2 NotificationCenter observers in init, **no deinit**); `AudioRecorderTests.swift` (only maxDuration tests) | **MED:** observer leak (each VM adds 2 permanent registrations) + the interruption/route/auto-finish durability paths are **untested** (§4H/S8). |
| Observability | `SentryBootstrap.swift` (crash only); `scripts/build-upload-asc.sh` (no dSYM upload); only 6 files use `os.Logger` (delivery/store) | **HIGH:** production crashes are **unsymbolicated** (no dSYM upload). Add the upload step (§4H/S1+S8) + os.Logger on the durability paths. |
| CI | none (`.github/workflows` absent) | The 150 tests / warning-free / i18n bars are hand-enforced on one Mac. Add a CI gate (§4H/S1) — lives outside the binary, zero app deps. |
| StoreKit loose ends | `Services/StoreService.swift` (`restorePurchases()` swallows errors; `Transaction.updates` task never cancelled); `Soundpost.storekit` (placeholder $9.99/$24.99 vs real ¥400/¥1,250) | Surface restore outcome; `deinit { listener.cancel() }`; sync `.storekit` prices (§4H/S8). |

## 4. Architecture / design decisions

**A. Personalized notification copy — privacy by default (S3).** Widen the
`NotificationCoordinator.sync` content closure's per-capsule map from `createdAt`
only to `{ createdAt, note, place.name, mood }`. When the **lock-screen-preview**
preference is ON, the body leads with the user's own one-line/place (e.g. *"'Rain on
the window' — sealed 8 months ago. Tap to listen."*); when OFF (**the default**), it
stays today's generic copy. The preference is a single `@AppStorage`
(`personalizedNotifications`, default `false`), toggled in Settings (S7). Rationale:
the content is the user's private words and renders on the lock screen, so the
honest default is conservative — opt **in**, not out. All variants localized
EN/JA/ZH-Hans. The server push stays content-free (M10 untouched); only the **local**
notification body changes, so no privacy posture moves. **P0 (Codex):
already-scheduled notifications carry the body baked at schedule time, and
`ContentView` resyncs only on the seal/echo *signature* — so toggling the preference
OFF would leave stale personalized text on the lock screen.** Changing
`personalizedNotifications` must therefore force a full reconcile (remove + re-add
this app's owned requests, or fold a content/privacy version bit into the scheduled
request identity so the planner re-issues them). Test ON→OFF reverts pending requests
to generic.

**B. Resurface-time normalization (S2) — the must-fix under the headline.** A reveal
is meaningless if the seal fired at 2:47 AM. Normalize the stored fire instant to a
**humane local hour** at write time via **one shared helper**:
`Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: chosenDay)` in the
capsule's `sealTimeZoneID` (seal) / device tz (echo). **P1 (Codex): the echo write
path is `CaptureViewModel.save` (which assigns `capsule.echoAt` directly) and
`randomEchoDate` (which carries the current time-of-day) — NOT `CapsuleStore.setEcho`**;
so the helper must be applied at `CaptureViewModel.save`, the picker `set`, *and*
`setEcho`/`seal`, or the main path is missed. This keeps the existing correct contract
(wall-clock + IANA tz; M10 `SupabaseDeliveryBackend.wallClockString` and
`NotificationScheduler.trigger` fire at the stored instant) — it only fixes the
*input*. **P0 (Codex): changing `sealUntil`/`sealTimeZoneID` while a seal is
server-owned must clear `serverJobSyncedAt`** — else the local planner keeps skipping
it (`NotificationPlanner` skips server-owned seals) AND `SealDeliveryService`
re-upserts only when `serverJobSyncedAt == nil`, so the Supabase job keeps firing at
the old 02:47 wall clock and the client never re-arms it. Verify the current
seal/unseal already clears it (re-seal is documented to); extend if not; a one-shot
normalization of existing server-owned seals must clear it to force re-upsert. Fix
the echoPicker `Binding` getter purity bug (it mints a fresh `randomEchoDate()` on
every body eval when `echoAt` is nil — seed once). **Tests:** stored `sealUntil`/
`echoAt` land on the chosen day at 09:00 in the stored tz across a tz boundary; a
**server-owned 02:47 job normalized to 09:00 re-upserts the new wall clock**.

**C. The resurface reveal (S4).** A dedicated `ResurfaceView` presented as a
**full-screen sheet** (not the nav push). **P1 (Codex): route *every* open through one
"open capsule" action** — gallery taps are plain `NavigationLink`s and the deep link
pushes detail today, and a `.sealed` capsule whose date has passed is already
content-visible *before* the `.resurfaced` flip. The single action: refresh due seals,
then present the reveal for a capsule that is **due `.sealed`** *or* `.resurfaced`,
else navigate to detail normally. Contents: elapsed time from `createdAt` ("Sealed
about 8 months ago" — no `sealedAt` field exists; `createdAt` is the honest proxy), a
gentle reveal transition **gated on `accessibilityReduceMotion`** (a cross-fade, not
melodrama), the one-line + place + mood, then **auto-offer playback** (reuse
`AudioPlayer`). Quiet, **skippable** (a clear Done/Dismiss), no share gate. The reveal
performs the deliberate flip that `markOpenedIfResurfaced` did silently. First open of
a reveal is the review-prompt trigger (S5). Honesty: it shows only the user's own
content; a sealed-not-due capsule never reaches the reveal.

**D. Calm gallery browsability (S6).** Over the existing single `@Query`: add
`.searchable` over `note` + `place.name`; a lightweight, collapsible filter (mood
chips + a sealed/resurfaced toggle); and "This month / Earlier this year / Older"
date sections. **Critical:** filtering/searching must stay **metadata-only** — never
read `audioData` (the documented M9 gallery-memory risk; reuse the `storageString`
estimate-don't-fault discipline). Filtering is in-memory over the small local set
(consistent with `CapsuleStore.sealedCapsules()` avoiding `#Predicate` on enums).
**P1 (Codex): search must be visibility-aware** — `note`/`place` are stored even
while sealed and are *hidden* on locked cards, so matching them in search would leak a
sealed-not-due capsule's hidden words. Search `note`/`place` only for
`isContentVisible()` capsules; a sealed-not-due capsule matches only non-sensitive
metadata (open date / state). Controls are secondary/collapsed — no counters, no
engagement loops. Free-tier: never gate finding your own memories.

**E. The Settings screen (S7).** A `SettingsView` reachable from the existing
toolbar (the entry point gets a clearer label/icon than `person.crop.circle`). It
hosts: privacy + support links (currently buried in the paywall); notification
status + a deep link to system settings (consolidating the reactive prompts in
`CaptureView`/`CapsuleDetailView`); iCloud/delivery state (reuse `CloudSyncMonitor`
backup states + `backupMessage` copy; move "Delete my cloud data" here from the
gallery footer); the `personalizedNotifications` toggle (S2/§4A); and the bulk
**export-your-data** affordance. Keep the gallery `storageFooter` focused on honest
durability copy. Also surface the **restore-purchases outcome** (the paywall's
`restorePurchases()` currently swallows errors). *Export-your-data:* writes a folder/
zip of per-capsule `.m4a` + a `manifest.json` (date, mood, place, note, seal/echo —
the user's own data) and presents the system share sheet. **P1 (Codex): build this as
a dedicated bulk-export actor, NOT a loop around `CapsuleExporter`** (which faults the
whole `audioData` blob and is `@MainActor`): fetch/export one capsule at a time off
the main actor, write its temp `.m4a`, release the blob before the next, build the
manifest separately, and preflight the estimated total size from clip durations (warn
before starting). This is distinct from M11's per-capsule Pro *share* export (a
privacy affordance, free).

**F. "Next to resurface" strip (S8).** An in-app "Upcoming" section (header or a
compact strip) showing the nearest due seals/echoes with a quiet countdown ("in 23
days"), sourced from the planner's nearest-due computation. Metadata-only; never
surfaces a sealed-not-due capsule's hidden content (only "a capsule opens in N
days"). A home-screen **WidgetKit** countdown is the higher-effort version (new
extension target + app group, still first-party/zero-dep) — an explicit **stretch**,
shipped only if slack remains; it must not gate the milestone.

**G. Milestone review prompt (S5).** A `@MainActor` helper that calls
`RequestReviewAction` (SwiftUI `requestReview` env action) only after a genuine
positive moment — **the first resurface reveal opened** — capped at once per app
version (`@AppStorage`), never on launch or mid-capture. Reuse `ggc读书:ReviewManager.swift`.
This is the ethically-correct trigger and reinforces the payoff rather than
interrupting it.

**H. Hardening & release-ops (S1 release-ops vi/vii + S8 rest).** (i) `AudioRecorder`: store the 2 observer tokens
+ `deinit { removeObserver }`; a `deinit`-cleanup convention pass over `AudioPlayer`
(Timer/session) and `StoreService` (`deinit { transactionListener?.cancel() }`,
`continue → break` on dead self). (ii) Tests: post synthetic
`AVAudioSession.interruptionNotification(.began)` + `routeChangeNotification(.oldDeviceUnavailable)`
and assert `onAutoFinish`/state (the recorder's "never lose a clip" guarantee is
untested); a reinstall re-registration integration test (registrar + a fake identity
returning the same key post-reinstall → exactly-one re-upsert). (iii) Surface key
swallowed errors (`restorePurchases`, seal/unseal `try?` at user-action sites →
toast/alert or `SentryBootstrap.capture`). (iv) `os.Logger` (category-scoped,
`.public` for non-PII only) on `AudioMigrator`/`AudioStore`/`CapsuleStore` writes/
`RemoteChangeReconciler`/`SoundpostModelContainer` fallback. (v) Sync `Soundpost.storekit`
displayPrices to the live tiers. (vi) **dSYM upload**: a Release-gated step
(`sentry-cli debug-files upload` run-script or a post-archive step in
`build-upload-asc.sh`) keyed off `SENTRY_AUTH_TOKEN` (env, like the ASC creds);
backfill shipped builds from their archives. (vii) **CI**: one GitHub Actions
macOS workflow running `xcodebuild test` on PR/main, failing on warnings + asserting
xcstrings 100%. (viii) A **Swift 6** strict-concurrency trial compile on a throwaway
branch (the posture is already clean — quantify the few gaps: the detached
transaction listener, `MainActor.assumeIsolated` in `RemoteChangeReconciler`, the
`@Sendable` closure injections) — documented, not necessarily flipped. (ix) A
**VoiceOver + Dynamic Type** pass on the new surfaces (reveal/Settings/filters) +
the paywall disclosure at the largest accessibility sizes; group the detail-view
play/pause+duration reading order; audit remaining mood tints for contrast (only
Joyful was fixed). *(Note: `WaveformView` already exposes an accessibilityValue for
playback progress — don't redo that.)*

## 5. Work breakdown (sequenced; each step compiles + passes tests + commits)

> **Re-sequenced per the Codex review:** release-ops (dSYM + CI) move **first** so
> every M12 change is symbolicated + CI-gated; the small correctness fixes are a
> committed step, not a droppable tail. **Committed core = S1–S6.** The **splittable
> tail** (peel off into M12.5 if the milestone slips) = **S7** (Settings + bulk
> export — large) and **S8** (the upcoming strip + the broad hardening sweep).

**S1 — Release-ops foundation + i18n cleanup *(do first)*.** §4H(vi/vii) + P2. Add the
**dSYM upload** step (Release-gated `sentry-cli debug-files upload`, keyed off
`SENTRY_AUTH_TOKEN`; backfill shipped builds from their archives) and a minimal
**CI** GitHub Actions macOS workflow (`xcodebuild test`, fail on warnings, assert
xcstrings has **no `new`/`needs_review`** strings). **Fix the i18n gap Codex found:**
`InfoPlist.xcstrings` JA/ZH usage strings are `needs_review` — mark them translated.
*Verify:* CI green on a PR; a deliberate test crash symbolicates in Sentry; the
i18n gate passes only when InfoPlist + Localizable are 100% translated.

**S2 — Resurface-time normalization (the headline precondition).** §4B. Centralize
seal/echo fire-time normalization to 09:00 local in **one helper**, used by **all
three** write paths — `CaptureViewModel.save` (the real echo path, not `setEcho`),
the echo/seal picker `set`, and `CapsuleStore.seal`/`setEcho`. **P0: any change to
`sealUntil`/`sealTimeZoneID` must clear `serverJobSyncedAt`** so the M10 reconcile
re-upserts the new wall clock (verify the existing seal/unseal already does, extend
if not); a one-shot normalization of existing seals must clear it too. Fix the
echoPicker getter purity. *Verify:* `CapsuleStore`/VM tests — stored `sealUntil`/
`echoAt` land on the chosen day at 09:00 in the stored tz across a tz boundary; a
**server-owned 02:47 job normalized to 09:00 re-upserts the new wall clock** (assert
via the delivery test doubles); the picker getter is pure.

**S3 — Personalized, privacy-safe notification copy + toggle reconcile.** §4A. Widen
the content map (note/place/mood); add `personalizedNotifications` `@AppStorage`
(**default off**); both variants localized EN/JA/ZH-Hans. **P0: when the preference
changes, force a full notification reconcile** (remove + re-add owned requests, or
fold a content/privacy version bit into the scheduled request identity) so stale
personalized text can't linger on the lock screen — `ContentView` resyncs only on the
seal/echo signature today. *Verify:* copy-builder unit test (personalized vs generic,
seal + echo); an **ON→OFF test proving pending requests revert to generic**; server
push unchanged (M10 tests green); i18n 100%.

**S4 — The resurface reveal.** §4C. `ResurfaceView` full-screen sheet; elapsed time;
Reduce-Motion-gated reveal; auto-offer playback; deliberate flip; skippable. **P1:
route every card-tap and deep-link through one "open capsule" action** — refresh due
seals, then show the reveal for a **due `.sealed`** *or* `.resurfaced` capsule, else
navigate to detail normally (a `.sealed` capsule past its date is content-visible
*before* the flip). *Verify:* a due seal (via notification **and** a card tap) opens
the reveal, not plain detail; Reduce Motion path is static; playback works; a
sealed-not-due capsule never reaches the reveal.

**S5 — Milestone review prompt.** §4G. `RequestReviewAction` after the first reveal,
capped per version. *Verify:* fires once after a reveal, never on launch/capture; cap
holds across relaunches.

**S6 — Calm gallery browsability.** §4D. `.searchable` + collapsible mood/sealed
filter + date sections; metadata-only. **P1: search is visibility-aware** — match
`note`/`place` only for content-visible capsules; a sealed-not-due capsule matches
only non-sensitive metadata (open date/state), never its hidden words. *Verify:*
search/filter never faults `audioData` (assert the gallery-memory discipline); **a
locked capsule's hidden note never appears in search results** (test); results
correct; i18n.

**S7 — Settings screen (+ export-your-data) *(splittable)*.** §4E. `SettingsView`
from the toolbar; privacy/support, notification + iCloud state, "Delete my cloud
data" moved here, the personalized-notifications toggle, restore-outcome surfacing.
**P1: bulk export is a dedicated streaming actor, NOT a loop around the `@MainActor`
`CapsuleExporter`** — fetch/export one capsule at a time, write its temp `.m4a`,
release the blob before the next, build the manifest separately, preflight total
size from durations and warn. *Verify:* export produces a playable per-capsule bundle
+ manifest **without faulting all audio at once** (assert peak memory bounded);
cloud-delete works from its new home; nothing Pro-gated; i18n.

**S8 — "Next to resurface" strip + hardening sweep *(splittable)*.** §4F + §4H(i–v,
viii–ix). In-app upcoming section (planner's nearest-due set; metadata-only; no
hidden content). Hardening: AudioRecorder observer-token storage + `deinit` +
**interruption/route/auto-finish tests**; `deinit` convention for `AudioPlayer`/
`StoreService` (cancel the `Transaction.updates` task, `continue → break`); the
**reinstall re-registration** integration test; surface restore/`try?` user-action
errors; `os.Logger` on the durability paths; sync `Soundpost.storekit` prices to the
live ¥400/¥1,250; a VoiceOver + Dynamic Type pass on the new surfaces + paywall
disclosure; a documented Swift 6 strict-concurrency **trial compile**. *(Widget =
explicit stretch.)* *Verify:* new tests green; warning-free; CI green.

> Drop order if time is tight: the **WidgetKit widget** and the **Swift 6 trial**
> first (both already deferred/optional); then split **S7** (Settings/export) into a
> follow-on. Never drop: **S1** (dSYM/CI), **S2** (seal-hour + `serverJobSyncedAt`),
> and **S3**'s toggle-reconcile — those are correctness/observability must-haves.

## 6. Privacy / legal delta

Likely **none** beyond honest in-app copy. M12 collects **no new data** and adds **no
backend**: the reveal/browse/Settings/upcoming are on-device; export-your-data is an
export-*your*-data affordance (file/share APIs — `FileTimestamp` C617.1 already
declared); personalized notifications change only the **local** notification body
(nothing traverses the server; the lock-screen-preview toggle is a *user privacy
control*, default conservative). No new Required-Reason API expected (confirm at each
step). **If the WidgetKit stretch ships**, the extension target needs its **own**
`PrivacyInfo.xcprivacy` (mirroring the app's) and reads only the user's own on-device
data — still no new collection. Keep the M10/M11 lockstep discipline: re-verify
PrivacyInfo + ASC label + policy at S7 (export) and any widget work; expect no
nutrition-label change.

## 7. Risks & mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| Reveal feels gimmicky / melodramatic | Med | Quiet, tasteful, **Reduce-Motion-skippable**; cross-fade not theatrics; clear Dismiss; no share gate (§4C). |
| Gallery search/filter faults `audioData` into memory (M9 risk) | Med | Keep the `@Query` + filtering **metadata-only**; reuse the `storageString` estimate-don't-fault discipline; assert in a test (§4D/S6). |
| Settings + filters turn a calm UI into chrome/engagement surfaces | Med | Secondary/collapsed controls, no counters, no nags; honor "minimal surface". |
| Bulk audio export is large / memory-heavy | Med | Stream per-capsule off the main actor; never fault all `audioData`; warn on total size (§4E). |
| Personalized lock-screen copy exposes private words | Med | Gated behind a preference, **default off (generic)**; opt-in only (§4A). |
| Seal-hour fix shifts already-scheduled seals | Low | Normalization applies at write time; a re-sync (`ContentView.refreshAndSync`) re-derives triggers; existing capsules keep their stored instant unless re-sealed. Document; optionally one-shot normalize on launch (only if safe). |
| Scope creep from the widget / deferred video export swallows the milestone | Med | Committed core = S1–S6; S7 widget + S8 Swift 6 are explicitly droppable; video export is a separate milestone (§11). |
| Standing bars slip across new surfaces | Med | CI (S1) enforces warning-free + tests + i18n on every PR; never-charge-to-receive holds (all M12 is free-tier). |
| Unsymbolicated crashes hide M12 regressions | High | dSYM upload (S1) before/with the next build; backfill shipped builds. |

## 8. Human-in-the-loop checklist (needs Jason)

- [ ] **Confirm the overridable product decisions** (my recommendations, all easy to
  change): lock-screen preview **default off / opt-in** (§4A); **defer the WidgetKit
  widget** (ship the in-app strip) (§4F); **defer in-app language override** (§2);
  review-prompt triggers on **first resurface**, capped 1/version (§4G); export =
  zip of per-capsule `.m4a` + `manifest.json` (§4E); reveal stays **quiet/skippable**;
  sequencing **reveal-first, browsability-second**.
- [ ] **`SENTRY_AUTH_TOKEN`** (and Sentry org/project slugs) in env for the dSYM
  upload step (S1) — mirrors how the ASC API creds live in `~/.zshrc`.
- [ ] **CI secrets** if the GitHub Actions runner needs signing — or scope CI to
  `xcodebuild test` (no signing) only, which needs no secrets (recommended).
- [ ] No App Store Connect product work is required for M12 (it's all free-tier);
  the M11 IAP review-screenshot + 1.4.0 submission remain the separate, already-flagged
  go-live tasks gated on 1.3.0 clearing review.

## 9. Reuse map

| Need | Source |
|---|---|
| Milestone review prompt | `ggc读书:GGCReader/ReviewManager.swift` (+ SwiftUI `RequestReviewAction`) |
| Settings / language override (if ever) | `Stride:.../LanguageManager.swift`; in-repo `CloudSyncMonitor` backup copy |
| os.Logger domains | `timeless:TimelessLogger.swift`; existing in-repo `Logger(subsystem:)` usage |
| Reveal transition / Reduce-Motion gating | in-repo `CaptureView` pulse + `WaveformView` `reduceMotion` patterns |
| Export / share plumbing | in-repo M11 `CapsuleExporter` + `ShareSheet` (extend for bulk) |
| Widget (stretch) | first-party WidgetKit; `FlowPilot:SharedDataService.swift` for app-group plumbing |
| Reinstall/sync tests | `Stride:StrideTests/SyncReconcileTests.swift`; in-repo `DeliveryRegistrarTests` |
| dSYM upload / CI | `sentry-cli`; in-repo `scripts/build-upload-asc.sh` (extend); standard GH Actions macOS |

## 10. Acceptance criteria

1. Opening a **due seal** (via notification or a resurfaced card) presents the
   **reveal** — elapsed time, the one-line/place/mood, Reduce-Motion-safe, auto-offer
   playback, skippable — not the plain detail screen.
2. A seal/echo set for a future day **fires at a humane local hour** (09:00 default)
   across tz boundaries — tested.
3. Resurface/echo notifications can carry the user's own one-line/place **only when
   the user opted in**; default is generic; all copy localized EN/JA/ZH-Hans.
4. The gallery is **searchable + filterable + date-sectioned**, all metadata-only
   (never faults audio — tested), never leaking a locked capsule's hidden content.
5. A calm **Settings** screen hosts privacy/support, notification + iCloud state,
   "Delete my cloud data", the personalized-notifications toggle, the restore
   outcome, and **bulk export-your-data** (streamed, size-warned, playable bundle +
   manifest).
6. An in-app **"next to resurface"** surface shows anticipation, metadata-only.
7. A **review prompt** fires only after a genuine resurface, capped per version.
8. Hardening closed: AudioRecorder observer leak fixed + interruption/route/auto-finish
   **tested**; reinstall re-registration **tested**; restore/seal errors surfaced;
   `.storekit` prices synced; os.Logger on the durability paths.
9. **dSYM upload** in the pipeline (crashes symbolicate); **CI** green on PR
   (warning-free + tests + i18n 100%).
10. **Standing bars hold:** warning-free; all tests green; i18n EN/JA/ZH-Hans 100%;
    **zero new third-party deps**; everything in M12 is **free-tier** (never charge
    to receive); M10 delivery + M11 Pro untouched.
11. **Accessibility (M7 bar):** the reveal, Settings, filters, and paywall disclosure
    are VoiceOver-labeled and don't clip at the largest Dynamic Type sizes; the
    detail-view playback controls read in a coherent order.

## 11. Out of scope / next

- **Video export milestone (M13?):** the animated-waveform **video** share (Pro) —
  the strongest deferred monetization lever, but the riskiest work (AVAssetWriter /
  AVVideoComposition: audio sync, render time, memory, file size). Its own focused
  milestone so M12's emotional + browsability work isn't held hostage. Static
  card+audio share already ships (M11).
- **Pro micro-levers:** custom mood color (clamp for text contrast — the M7 finding)
  + custom echo window — small, lapse-safe, additive; bundle with the video milestone.
- **Promo / offer + win-back codes:** lowest ROI, mostly ASC config; win-back risks a
  dark pattern that contradicts the anti-FutureMe trust positioning — defer until
  launch traction.
- **Home-screen widget** (committed): the in-app strip is M12's version; promote the
  WidgetKit target to a committed deliverable post-M12 if it earns its keep.
- **Engineering hardening (ongoing):** flip Swift 6 once the trial quantifies it; grow
  the test net; keep warning-free + i18n 100% + zero new deps as standing bars.
