# M23 — "Doors people can find"

> Status: **PLAN, revision 4** (2026-11-11), after round 1 (Gemini 3.8 Flash (high) via `agy`, and four
> independent review lenses, every finding re-checked against the code by a separate skeptic) and round 2
> (Gemini 3.8 Flash on revision 2, and a consistency review of the whole document), and round 3 (Gemini
> on revision 3: every round-2 change confirmed, two small fixes) — §12.
> Grounded at `55d3563` by seven read-only investigations (the carried ledger; the store location and a
> later content widget; far-seal delivery; platform debt; usage levers inside the rules; the widget
> extension's quality; release/CI tooling and the new app-hang report), plus fresh reads of Sentry, App
> Store Connect and the delivery database on 2026-11-11. Every claim names its file and line at
> `55d3563`; **re-verify before you change anything.** Starting facts: `docs/M22-DEVPLAN.md` §8, §11,
> §13. **1.12.0 (build 24) is WAITING_FOR_REVIEW** (submitted 2026-11-10 18:29 JST, `releaseType
> MANUAL`); it goes live only on Jason's word.

---

## 0. Goal & success statement

**What the data says (facts, 2026-11-11).** Sentry, last 30 days: 1.10.0 — 5 sessions (~3 users);
1.11.0 — 2 (~2); 1.12.0 — 2 (~2, App Review). No crash. One new issue: "App Hanging ≥ 2000 ms" on
1.12.0 (24), iOS 27.1, device model `iPhone99,10`, 2026-11-10 09:36 UTC — seven minutes after
submission; the main thread waits in the kernel inside a Core Animation commit with no Soundpost frame
below `main`, right after keyboard show/hide breadcrumbs (§3.9). The delivery database is unchanged
since M21: 3 pending jobs (one `no_tokens`, overdue and retried hourly; the only user with a token has a
job due in 2028), 2 production tokens, **no row has ever reached `status = 'sent'`**,
`0003_m21_hygiene.sql` not applied. Usage — not stability — is still the constraint, and nothing
outside the app brings anyone to it: promotional text has been empty on the store since 1.9.0; the
store screenshots are four raw 6.5-inch captures from 2026-09-16 that show nothing from 1.10–1.12; the
JA / ZH keyword fields use 52 and 45 of 100 characters; and the app itself never mentions the capture
doors M20 and M22 built.

**What M23 does.** Make the doors findable — in the app (a calm "Ways to start a capsule" section in
Settings) and on the store (screenshots that show today's app, filled keywords, corrected promotional
text) — and start measuring (App Store Connect analytics, requested in S1 so a baseline exists before
the listing changes). Around that: make the release path unable to lose an archive or ship without
`MANUAL` release (the 1.12.0 app bundle vanished from the iCloud-synced `build/` on 2026-11-10 —
§3.8); run CI on the toolchain that actually builds the shipped binary; pin the SwiftData store's
location so a later App Group cannot move the library (the first half of M22 D10); close the one
delivery orphan that needs no server change; pin and polish what 1.12.0's widget shipped without a
test; and witness — or stop claiming — what the listing says.

**Success** — all of these hold for the 1.13.0 build:

- Settings shows a **"Ways to start a capsule"** section: Siri's own tip for the shipped phrase (a
  dismissed tip stays dismissed), a Shortcuts link, and one literal line each for the widget and (iOS
  18+) Control Center — seen on the iOS 27 **and** iOS 18.5 simulators in EN, JA and ZH-Hans, recorded
  in §13. Nowhere else in the app mentions a door; nothing appears by itself.
- `asc.py` **refuses** to attach or submit a version whose `releaseType` is not `MANUAL`, before any
  write (including `cmd_submit`'s cancel of an old draft); `create-version` sends `MANUAL`. Each pinned
  by a test that fails without the guard.
- A release archive is written **outside `~/Documents`** (Xcode's Archives), under a name that carries
  its version and build; nothing in the release path deletes or overwrites an archive; the tag is
  pushed by the script — each pinned by a `test_gates.py` fixture that drives the extracted policy.
- `release-preflight.sh` passes on a clean tree **without any override** when the only untracked files
  are other sessions' files under `.claude/`; no override can skip the HEAD-unchanged guard or let an
  upload proceed without dSYMs reaching Sentry.
- `asc.py check-submittable` (read-only) lists every reason a version cannot be submitted — including an
  unanswered age-rating question on the **editable** app info and a stale screenshot display type — and
  `submit` refuses on any of them.
- CI runs **every** gate on **Xcode 27.2** (the toolchain that built 1.11.0, and presumably 1.12.0), and
  the release refuses an archive whose `DTXcodeBuild` differs from the one CI ran (if S2's Xcode 27 job is
  dropped, S2.3's CI half goes with it and this line reads "the release refuses an archive whose
  `DTXcodeBuild` differs from the pinned local build" — §2).
- Both on-disk store rungs pass `groupContainer: .none`, and a test proves the resolved store URL is
  today's (`Application Support/default.store`). No user-visible change.
- A re-seal that replaces a stamped far seal queues a durable cancel for the old server job, and a far
  seal's queued cancel is resolved only once the server holds the new seal — no server change.
- Each widget face is one VoiceOver element, "New capsule"; M22 D14's locations, the accent glyphs, the
  circular background and "the face reads nothing from its timeline" are pinned by tests.
- The store listing for 1.13.0 carries new screenshots captured from the real app (6.9-inch, fixed
  status bar, daytime demo clock), no stale 6.5-inch set, filled JA / ZH keywords, and — on Jason's
  approval of the exact three texts — promotional text that is literally true.
- **"Lock Screen" appears in the app or the listing only if a Lock Screen face has been seen** (S6 or
  H4); otherwise S7 removes it from the description's doors line in all three locales.
- Standing bars at every commit (§1.7).

**Not success:** a Settings section seen only in English, or on one OS; a "MANUAL" check that reads the
attribute but sits after a write; an archive "preserved" by a copy nobody verifies; a preflight that
passes because its scan root is empty or missing (M15 §11P); a fixture that fails against the *old*
script for an unrelated reason (missing key, keychain) and so proves nothing; a store-pin test that
compares a URL with itself; screenshots that show a state the app cannot produce (M19 §4A rule 3); a CI
job that is green because it ran a subset of the gates; "Lock Screen widget" shipped unseen for a
second release.

---

## 1. Non-negotiables (carried from M22 §1; rule 5 restated)

1. **Calm, honest, literal copy** in EN · JA · ZH-Hans. Every sentence is literally true of the build
   in every state it can be shown in. No "quickly", "instantly", "never miss", no exclamation (no すぐ /
   瞬時 / 見逃さ; no 快速 / 立即 / 错过; no `!` / `！`). Store text (promotional text, keywords, captions
   if any) is copy too. No gate checks rule 1 for in-app strings: new strings are reviewed by hand and
   the review is recorded in §13.
2. **No counters, streaks, nags or engagement prompts. No new notification kind.** The Settings section
   and any About rows are **passive**: they are there when someone opens Settings and never present
   themselves, badge, or reappear once dismissed.
3. **Free stays free; Pro stays hidden.** `ProOffer.isOnSaleInThisBuild` stays `false`
   (`Soundpost/Models/ProGate.swift:136`) unless Jason decides otherwise (D1, D16).
4. **No new CloudKit field or entity; no Console deploy.**
5. **No new target, App Group, entitlement or deployment-target raise.** The store pin changes no
   entitlement; nothing in M23 adds one (the content widget is M24 — §11). Zero new dependencies.
6. **Delete no audio** except the user's own explicit delete.
7. **Standing bars at every commit:** warning-free on CI's Xcode (26.6, and from S2 also 27.2) and on a
   clean local Xcode 27 build (`xcodebuild clean test` in place); all tests green with the executed
   **count** confirmed (CI floor `MIN_TESTS`, now **752**, and from S2 `MIN_PY_TESTS`, now **78** —
   raise both with every step); i18n 100% per target; CI green on the pushed commit, every job. Every new
   test is seen to fail against a deliberately broken implementation (`cp` snapshot, never `git
   checkout`; `-collect-test-diagnostics never`); every gate or tooling change has a fixture that the old
   code passes **for the reason under test** and the new code fails. Record mutation → failing test in
   §13.
8. **Builds go through the shared package checkout** (`CLAUDE.md`, `scripts/lib/build_cache.sh`): one
   derived-data root for this checkout, reused across steps; never under `~/Documents`.
9. **Production is Jason's.** Supabase `gkjwsxotmwrgqsvfijzs` is shared with other apps; any migration,
   function deploy or row change there is **done by Jason** (the agent prepares the exact command and
   the before/after reads). Agent reads select only the columns they need, never `token` or a full
   `user_key` (§4A). App Store Connect writes outside the release path (the analytics request, the
   promotional-text push) happen only on Jason's explicit word for that action, recorded in §13.
10. **No new public door.** No URL scheme is registered.
11. **The existing doors do not change.** `OpenCaptureIntent.swift` stays byte-for-byte (its SHA256 is
    pinned by `CaptureDoorTests`); the Settings section *constructs* the intent for the tip, never
    performs it.
12. **Simulators by the global rules:** listed devices by UDID only, `/tmp/lock-<slug>`, no boot under
    30 GB free without Jason's explicit exception; every witness batched into one boot per device (S6).
    While disk is under 30 GB, local test runs (S1–S5) use the already-booted shared `iPhone 17 Pro`; no
    other device is booted for them.
13. **§13 is public** (the repository is public). Production reads are recorded as Jason's own rows (job
    id and an 8-character key prefix) or as counts and states — never another user's key prefix, due
    date or time zone.

---

## 2. Scope

| Step | What | Size | Human step |
|---|---|---|---|
| **S0** | Witness one APNs push to a phone with a token (carried since M21); D3 | S | **Jason, in parallel** |
| **S1** | Release safety: policy extracted and tested; `MANUAL` guard; archives leave iCloud, never overwritten; tag push; preflight scope, one dirty rule, named overrides; dSYMs required on upload; screenshot-name policy; `check-submittable`; Sentry probe; venv; how screenshots reach the store (read-only); analytics request | M–L | D5 (the POST) |
| **S2** | CI on the shipping toolchain: an Xcode 27.2 job running every gate; the release's toolchain pin; a tested simulator picker; pre-boot; a Linux job for the delivery-server tests; (D23) retire 26.6, then W7 | M | D23 |
| **S3** | The store stays where it is: `groupContainer: .none` on both on-disk rungs, a URL-identity test | S | none |
| **S4** | Doors people can find: the Settings section; widget pins and VoiceOver; (D17) passive Share / Rate rows | M | D17 |
| **S5** | Delivery, app-only: the re-seal orphan and a far seal's queued cancel; a content-free APNs failure reason prepared (Jason deploys); B2 only if S0 passed, D3 is applied and D11 = yes | M | D3, D11, Jason's deploy |
| **S6** | One witness pass per simulator: S4 in three languages on two OSes, the widget's unseen states, a warm control tap, the Lock Screen attempt; screenshots v2 | M | **H2 disk** |
| **S7** | 1.13.0 (build 25): screenshots (no stale set), keywords, notes, description fix if unseen; promotional text (D6); upload, submit | M | D6, **H1**, H4 (or its absence), H5, H6, **Jason says release** |

**Drop order if tight:** S2's Linux job (then the 27.2 job keeps the delivery-server step, and D23 does
not retire the 26.6 job while it is the only one running it) → S4's RenderPreview spike (§4E.4) → S2's
simulator-picker script (keep the explicit names inline) → S4's About rows → S2's Xcode 27 job (dropping
it also drops S2.3's CI half and W7; `release-toolchain.env` stays, pinned to the local build; §0's
toolchain line is reworded as it says).
**Never drop** S1's `MANUAL` guard, archive safety and dirty rule, S3, S5's orphan fix, S4's Settings
section, or S6/S7's rule that the listing claims only what was seen.

---
## 3. Current state (grounded 2026-11-11 at `55d3563` — re-verify)

### 3.1 Release and versions

- 1.12.0 (24) `WAITING_FOR_REVIEW`, review submission `3b403d1a-…`, `releaseType MANUAL` (read back by
  hand; nothing in `asc.py` checks it — `grep releaseType scripts/*.py` finds only the docstring at
  `asc.py:210`). App Store Connect allows one editable version at a time: **1.13.0 can be created only
  after 1.12.0 is released.** If 1.12.0 were withdrawn instead, its record becomes `DEVELOPER_REJECTED`
  and stays the editable version (the project's precedent renamed such a record, 1.0 → 1.1.0); `asc.py`
  has no rename command and `create-version` would fail — that branch needs its own plan (H1).
- `cmd_create_version` posts only `platform` and `versionString` (`scripts/asc.py:240-243`) and returns
  an existing version untouched (`:235-239`). `cmd_attach` (`asc.py:303-323`) and `cmd_submit`
  (`:363-415`) never read `releaseType`; each begins `v = editable_version()` then `if not v: sys.exit(…)`. `cmd_submit`'s first write can be indirect: `cmd_cancel(force_cancel)`
  (`asc.py:380`) PATCHes `canceled: True` (`:351`) before the first direct `post`.
- `req()` checks the app only on writes (`asc.py:72-74`); `check-build-number` is a read that checks the
  app first (`asc.py:599-607`).
- The age-rating declaration is read through `appInfos/{appInfoId}/ageRatingDeclaration` (the
  declaration's own GET answers 403 — M21 §13, `docs/M21-DEVPLAN.md:985`). While a version is in flight
  the app has **two** app infos, each with its own declaration (M22 §13 records the new one,
  `7a6b2bb1-…`); `asc.py` has no appInfos code today.
- Versions live at project level only (M22 S1): `MARKETING_VERSION 1.12.0`, `CURRENT_PROJECT_VERSION 24`.
- `asc.py` cannot push promotional text, subtitle, name, in-app events or analytics requests
  (`asc.py:173-650`); `push_localized_field` writes only to the editable version (`asc.py:249-284`).

### 3.2 Archives, the preflight and dSYMs

- `build-upload-asc.sh` sets `ARCHIVE_PATH` / `EXPORT_PATH` defaults to `build/Soundpost.xcarchive` /
  `build/Export-Soundpost` inside `~/Documents` (`scripts/build-upload-asc.sh:29-30`) — before
  `VERSION` / `BUILD` are read (`:73-74`) — and `rm -rf`s both before archiving (`:94`). Each release's
  previous archive has been copied out by hand first; tag push is manual. `verify-archive.sh` and
  `upload-dsyms.sh` already take the archive path as an argument; `upload-dsyms.sh --backfill` already
  scans Xcode's Archives (only its comment at `:56-57` is stale). So the defaults at `:29-30` are the only
  literal consumers. An archive records its upload in `Info.plist` (`Distributions[].destination =
  upload` with `uploadEvent.state = success` — 1.11.0's archive).
- Both scripts take `PROJECT_DIR` from their own location (`build-upload-asc.sh:24`); neither honours
  `GATE_PROJECT_DIR`. `build-upload-asc.sh` exits early without the ASC key file (`:36-40`), runs the
  CloudKit status check in upload mode (`:54`, `CK_SKIP_SCHEMA_CHECK`), and calls the preflight,
  `verify-archive.sh` and `upload-dsyms.sh` through `$PROJECT_DIR/scripts/…` (`:67, :110, :141`). The
  preflight always runs a keychain / codesign probe, which fails on a CI runner (no signing). **No
  `test_gates.py` fixture covers either script today** (its classes: ProjectModel, Localization,
  Warnings, DebugOnly, Version, Archive).
- The preflight's copy scan prunes only `.git` and `build` (`release-preflight.sh:52-58`). Its clean-tree
  check (`:88-91`) and `build-upload-asc.sh`'s post-archive HEAD-unchanged guard (`:118-127`) both run
  `git status --porcelain --untracked-files=all`, which counts any untracked file git does not ignore —
  `.git/info/exclude:8` ignores only the exact name `**/.claude/scheduled_tasks.lock`, so another
  session's `.claude/scheduled_tasks 2.lock` made the tree "dirty". One override
  (`RELEASE_PREFLIGHT_OVERRIDE=yes`, documented at `:19-24`, read at `:128`) skips the preflight **and**
  turns off the HEAD guard and the dSYM fatality in `build-upload-asc.sh` (`:118-127, :145-151`). Both
  1.11.0 and 1.12.0 shipped under it; the HEAD and dSYM checks were redone by hand. D9's empty
  `metadata/* 2` folders and the stale lock copy were trashed on Jason's word on 2026-11-10.
- `upload-dsyms.sh` **exits 0** when `sentry-cli` or `SENTRY_AUTH_TOKEN` is missing (warn-and-skip,
  `:23-32`); `build-upload-asc.sh` treats only a non-zero exit as a dSYM problem; the preflight's token
  check (`:110-119`: `sentry-cli` present, token set, no `<` prefix) is the only thing that catches an
  unset token. The ASC venv lives in `/tmp` (`:100-102`).
- `cmd_screenshots` uploads every `.png` in a locale folder (`asc.py:508-516`), replaces only the set
  whose display type equals `SCREENSHOT_DISPLAY_TYPE = 'APP_IPHONE_65'` (`asc.py:441, :520-521`) and
  never touches a set of another type; it deletes images with `DELETE /v1/appScreenshots/{id}`
  (`asc.py:541, :574`). A note in Jason's RoastMate repo (`RoastMate/scripts/asc_product_page.py:41-43,
  :136-137, :151`, 2026-10-14) says `appScreenshotSets` are deprecated in favour of App Asset Library
  placements, that Apple maps that DELETE onto an image delete which can hit images the live version
  still shows, and that the display-type enum has `APP_IPHONE_67` (not `_69`) for 1320×2868. **None of
  this is verified against Apple's current documentation** — S1 settles it read-only before any upload
  (§4B.7).

### 3.3 CI

- One job, `macos-26`, `EXPECTED_XCODE "Xcode 26.6"` asserted, `MIN_TESTS "752"` under the job's `env`,
  30-minute timeout (`.github/workflows/ci.yml:31-43`). Steps include "Release-tooling policy tests" (the
  only step running `test_asc_policy.py` and `test_gates.py` — 78 Python tests; it checks only `Ran
  [1-9]…`) and "CloudKit seed coverage". The last 30 runs: 27 green; the 3 red were all on 2026-11-08 (two
  GitHub download outages, one Deno type-check); 17 green since. HEAD's run used 24.1 of 30 minutes —
  most of it simulator boot / install between the end of the build and the first test (2m11s–12m43s).
- The simulator picker is inline Python in the workflow (`ci.yml:182-189`): the first device whose name
  starts with "iPhone" on the newest runtime.
- The delivery-server step turns a failed Deno install or `deno cache` into a warning and a green step;
  its SQL test has **never run on CI** (no Postgres on the macOS runner — `ci.yml:117-151`).
- **Shipped binaries are built with local Xcode 27.2 (27B52, `iphoneos27.2`)** — read from 1.11.0's
  archive (`DTXcodeBuild 27B52`); 1.12.0 presumably the same, unreadable since its app bundle is gone;
  `/Applications/Xcode-27.1.app` is also installed. CI never compiles with it. Xcode 27 has raised warnings 26.6 does
  not (`check-warnings.sh:48`, `ContentView.swift:3-5`). No release script reads `DTXcodeBuild` /
  `DTSDKName`. Xcode is an App Store install with auto-update on, so 27B52 can change under the plan.
  GitHub's `xcode-27` runner image is reported GA since 2026-10-15 with Xcode 27.2 present but 27.1 the
  default, and an iOS 27.2 runtime whose only device is `iPhone Duo` (which the current picker could
  choose). **Unverified by the grounding; S2.1 reads it first.**
- App Store minimum: Xcode 26 / iOS 26 SDK since 2026-04-28; no iOS 27 SDK requirement announced.

### 3.4 The store location

- Both on-disk rungs build `ModelConfiguration(schema:cloudKitDatabase:)` with no `groupContainer` and
  no `url` (`Soundpost/Services/SoundpostModelContainer.swift:75` CloudKit `.automatic`; `:99`
  `.none`), so SwiftData's default `groupContainer: .automatic` applies (iOS 27.2 SDK
  `SwiftData.swiftinterface:36-47`: `.automatic`, `.none`, `.identifier(_:)`; no doc comment).
- Read from the iOS 18.5 runtime's SwiftData binary (and the same strings in 27.0): with `.automatic`
  the resolver reads the first `com.apple.security.application-groups` entitlement and resolves into
  that group container; without one it uses Application Support. When the resolved store is missing it
  looks for the store at the `.none` location and **copies** it with `replacePersistentStore` ("Moved
  default store into new location") — so M22 D10's "a different, empty store" is likely wrong in
  mechanism; whether the copy carries external-storage audio (`Capsule.audioData`) and the CloudKit
  mirroring metadata, and what iOS 17 does, is **unknown**. The app has no App Group today
  (`Soundpost/Soundpost.entitlements`: iCloud container, CloudKit, `aps-environment` only).
- `ModelConfiguration.url` is a public stored property, so a test can read where a configuration
  resolves without building a container. All test containers are in-memory (`TestSupport.swift:27,
  :117`), which ignore group containers.

### 3.5 The widget extension (1.12.0)

- Correct against the SDK at iOS 17.0: `containerBackground(for: .widget)`, `AccessoryWidgetBackground`,
  `widgetAccentable`, `disfavoredLocations` (`.carPlay` behind iOS 26), `widgetURL`; the control behind
  iOS 18. iPhone-only (`TARGETED_DEVICE_FAMILY "1"`), portrait-only.
- **Held by no test:** M22 D14's disfavoured locations (`SoundpostWidget/LauncherWidget.swift:21-29`),
  `widgetAccentable` on the three glyphs, `AccessoryWidgetBackground` in the circular face (`:65-91`),
  and that the view ignores its timeline entry (discarded at `:13-14`).
- **VoiceOver:** only the circular face is one element labelled "New capsule" (`:72-73`); the small and
  rectangular faces expose the glyph separately.
- **Never seen:** any Lock Screen face (the simulator would not open Lock Screen customization — M22
  §13 S3); Dynamic Type at accessibility sizes; JA / ZH faces; dark / tinted / clear Home Screens; a
  **warm** control tap (app in the background); a widget tap during a take; StandBy; the control on the
  Lock Screen or Action Button. 1.12.0's listing claims a Lock Screen widget in three locales
  (`metadata/*/description.txt:13`, `release_notes-1.12.0.txt:1` — the first release to carry it);
  `NewCapsuleControl.swift:5-6`'s doc comment claims Lock Screen and Action Button placements.
- On iOS 27 the SDK says an intent may run in **any** target that contains it
  (`AppIntents.swiftinterface:7228-7229, :7687-7702`, `allowedExecutionTargets`, iOS 27.0).
  `NewCapsuleControlIntent` is compiled into the extension, where `CaptureRequests.coordinator` is nil:
  if iOS 27 ran a warm tap there, the app would open on the gallery with no capture request. Only cold
  taps have been seen. `allowedExecutionTargets = .main` needs the iOS 27 SDK, which CI's 26.6 lacks,
  and the shared file allows no `#if` (`CaptureDoorTests.swift:204`).

### 3.6 Doors and discoverability

- The doors: App Shortcut / Siri / Spotlight / Action Button (`OpenCaptureIntent`, M20 S5), the Home
  Screen quick action, the widget and the iOS 18 control (M22). The app never mentions them;
  `SettingsView` has notifications, listening, data, iCloud, (Pro / personalisation), About
  (`Soundpost/Views/SettingsView.swift:66-78`; About at `:345-351`: Privacy Policy, Terms, Help).
- `SiriTipView` has one initialiser, `init(intent:isVisible: Binding<Bool>? = nil)`
  (`_AppIntents_SwiftUI.swiftinterface:47`); `ShortcutsLink` and `ShareLink` exist at iOS 16; a probe
  typechecks all of them, and `URL.appending(queryItems:)`, at iOS 17.0.
- Every surface that describes a door pairs it with "Opens Soundpost ready to record. Recording starts
  only when you tap." — an existing, translated key (`Localizable.xcstrings:2187`, used by
  `OpenCaptureIntent.swift:10` and `CaptureDoor.swift:80`).
- The call-site censuses live in `CaptureDoorTests` (`:150-171`: exactly one `startRecording` site,
  capture shown at its four places, exactly one `requestCapture` site) over `shippingSources()`.
- The only rating path is the once-per-version system prompt after a resurface reveal
  (`Soundpost/Services/ReviewPrompt.swift:13-32`). Sharing a capsule requires `ProGate.canExport` =
  `isPro`, false for everyone while Pro is off sale (`ProGate.swift:30, :126-131`).

### 3.7 The store listing and screenshots

- Promotional text: empty on App Store Connect; the repo copy (`metadata/*/promotional_text.txt`, from
  M8) ends "Private, offline, and honest by design." / 「プライベートでオフライン、そして正直な設計。」/
  「私密、离线、坦诚设计。」 — the app now syncs through iCloud and keeps device tokens and far-seal
  schedules on a server, so a bare "offline" is no longer literal (rule 1).
- Keywords: en 96/100; ja 52/100; zh-Hans 45/100. Subtitles ja / zh 11/30; the ja name 「音信」(2/30)
  disagrees with `docs/PROJECT.md:14`.
- Screenshots: one `APP_IPHONE_65` set per locale, 1242×2688, four images, captured 2026-09-16 with a
  real 1:36 clock and "1:33 AM" card times; a new version inherits the previous version's sets.
  `scripts/screenshots.sh` creates `Soundpost-Shots` (a temporary iPhone 11 Pro Max device the global
  rules list), checks for exactly 1242×2688 (`:171-172`), calls `red` (`:57`) before defining it
  (`:61`), takes no device lock, and stages screens with `-screenshotScreen` (`SCREENS=(gallery detail
  search capture)`, `:47`; hook at `ContentView.swift:117-144`). It deliberately leaves Settings out:
  on a capture simulator with no iCloud account, the iCloud row says capsules live only on this device —
  a contradiction of the listing's sync line. The shared `iPhone 17 Pro Max` (iOS 27.0) is the global
  table's 6.9-inch screenshot device.

### 3.8 The 1.12.0 archive

- `build/Soundpost.xcarchive` (1.12.0 / 24) has an **empty `Products/Applications/`**. The signed app
  bundle disappeared on 2026-11-10 at 20:46 JST — the same minute Finder rewrote `build/.DS_Store`, one
  minute before Jason's D9 message, with no write by the agent's session (its transcript has none). It
  is not in the Trash and Spotlight finds no copy. The dSYMs (`Soundpost` B9FBB6D4-…, extension
  D83420E1-…) remain and **are in Sentry** (uploaded 2026-11-10 09:25 UTC). What is left was copied to
  `~/Library/Developer/Xcode/Archives/2026-11-10/Soundpost 1.12.0 (24) - app bundle missing.xcarchive`
  (`diff -rq` identical). App Store Connect holds the uploaded binary, so nothing a user sees is
  affected; the loss is the local re-export path for build 24. **Archives in iCloud Drive are not safe
  storage** — S1 moves them out.

### 3.9 The app-hang report

- `iPhone99,10` matches no device type on this Mac; the app started 3 minutes after submission while
  the version was `WAITING_FOR_REVIEW`; the main thread was waiting in the kernel (not computing) in a
  CA commit; every screen with a keyboard does trivial per-keystroke work, and sound classification
  runs off the main thread. Reading: a system/review-device stall, not Soundpost code. **No code change
  in M23**; after 1.12.0 is live, check Sentry weekly for the same signature on public device models
  (filter out `device.model:iPhone99*`), and reopen only on a real-device recurrence or a Soundpost frame.

### 3.10 Delivery (far seals)

Definitions (never written down before; M22 used them): **B2** — keep a stamped seal's server job
through its last day *and* plan the local reminder inside the 24-hour horizon. **B1** — keep the job
through the last day and rely on the push alone (no local reminder in the last day).

- Every carried item is still present (M22 changed none): the multi-device last day (item 1, D11) — a
  sibling's sync inside the horizon cancels the job that is every device's push
  (`Soundpost/Services/Delivery/SealDeliveryService.swift:15, :28-35, :121-135`); cancels keyed by
  `(user_key, capsule_id)` only (item 6; `backend/supabase/migrations/0001_m10_delivery.sql:211-219`;
  `functions/sync-delivery/index.ts:141-148`, which ignores unknown body fields).
- **The offline unseal → re-seal orphan.** `unseal` keeps the stamp so the cancel loop can cancel, a
  failed cancel keeps it, and a later `seal()` clears it (`CapsuleStore.swift:131, :276-280`;
  `SealDeliveryService.swift:135-139`), so a re-seal inside 24 h leaves the old far job to push "A
  capsule has resurfaced" on the old date. `normalizeSealHours` (`CapsuleStore.swift:365-376`, called at
  `ContentView.swift:608` with `try?`, saved at `:610`) can do the same to a legacy stamped seal — and it
  clears `serverJobSyncedAt` itself (`:375`) before returning, so its return value cannot say which
  capsules were stamped. The drain (`SealDeliveryService.swift:268-296`) decides each queued id by a
  fresh fetch and resolves a stored far seal's entry **without** a network call — even when the server
  does not yet hold the new seal; the cancel loop considers only stamped capsules.
- The detail seal writes through `store.commitSeal(` (`CapsuleDetailView.swift:572-596`), pinned by
  `WriteFailureViewGuardTests.swift:18-24` and `CaptureSealTests.swift:171`; the delete path already
  goes through `CapsuleActions.delete` (`CapsuleActions.swift:26-48`) with a durable pending cancel.
- Why nothing has reached `sent`: the only due job's user has no token (deferred an hour at a time,
  forever — what `0003` bounds); the only user with a token has its job due in 2028. A `sent` row is
  deleted at the next sync after the capsule's due time (the app's cancel is a hard delete, as the
  privacy delta promises), so the table alone cannot prove a push was never sent.
- A seal ≤ 24 h ahead never gets a server job (`SealDeliveryService.swift:15, :32`); the seal sheet
  sets 09:00 local.
- A rejected APNs send is stored only as `dispatch_failed`: `apns.ts` reads the APNs reason but returns
  only `http_<status>` on retry (`functions/send-due-notifications/apns.ts:143-159`); `index.ts` keeps
  only `outcome.status` (`index.ts:180-197`) and writes a fixed `dispatch_failed` on both the retry and
  dead-letter branches (`:209-229`). `apns_test.ts` tests only `apnsHostFor`; `state_test.ts` tests
  `state.ts` with in-memory outcomes and never runs `apns.ts`. If S0 fails, nobody can see why.
- The repo's `apns.ts:134` fix (M22 S1) is **not deployed**; the deployed function is older.

---
## 4. Design decisions

### 4A. S0 — the push witness (Jason; the agent reads only)

The agent gives Jason this in plain Chinese on day one, with the queries ready. **Every read selects
only `id`, `status`, `attempts`, `last_error`, `wall_clock`, `time_zone`, `locked_at`, `updated_at`,
`environment` and `left(user_key, 8)` — never `token` or the full `user_key`** (the key is the bearer
credential for `sync-delivery`); §13 records the job id and that prefix only. Two options (D15):

**Option A (recommended: ~15 minutes, one production row change by Jason).**
1. On his phone, App Store build, notifications allowed for Soundpost, iCloud signed in, never used
   "Delete my cloud data". Force-quit, cold-launch once. The agent reads `device_tokens` and confirms his
   row's `updated_at` is today. If not, stop: registration is the problem (investigate first).
2. Record a short capsule with the note "S0", seal it in the calendar to **the day after tomorrow** (not
   a quick pick; ≤ 24 h never gets a server job). Keep the app open ~10 s.
3. The agent reads `notification_jobs` (and confirms `locked_at is null`) and gives Jason the job's `id`
   and this one statement for the SQL editor of `gkjwsxotmwrgqsvfijzs`:
   `update public.notification_jobs set wall_clock = (now() at time zone time_zone) + interval '3 minutes', next_attempt_at = now() where id = '<id>' and status = 'pending';`
   (the poller fires when `(wall_clock at time zone time_zone) <= now()` and `next_attempt_at <= now()`,
   `0001_m10_delivery.sql:240-264`; the capsule stays a stamped far seal in the app, so no sync upserts
   or cancels it).
4. **Force-quit Soundpost, then lock the phone.** The agent reads the row each minute and records
   `status = 'sent'`. In Option A the row stays `sent` until the capsule's last day, so opening Soundpost
   afterwards is safe.
5. Jason taps the push from the killed app. **Expected:** it opens the S0 capsule's detail, still sealed
   (Option A does not witness the reveal). Then he unseals the S0 capsule (otherwise it reminds on its
   date).

**Option B (no production write; witnesses the real path, reveal included).** Steps 1–2; then **no
Soundpost on any device of that iCloud account for the 24 hours before the seal's 09:00** (a hand-back
from an app open or a background CloudKit import cancels the job); then the agent reads `sent` before
anything is opened (after the due time, any sync deletes the row), and Jason taps from a killed app.

If S0 ends `dispatch_failed` or keeps retrying: S5.2 (server-only, independent) moves ahead of S2–S4,
Jason deploys it, and S0 is repeated. **D3** (apply `0003_m21_hygiene.sql`) does not touch the send path
and is independent of S0; the agent re-runs `backend/supabase/tests/run-local.sh` first and prepares
before/after reads (one cron row `m21_delivery_hygiene` `17 3 * * *`; at the first nightly run more than
seven days after its due time the `no_tokens` job reads `failed / no_tokens_expired`, recorded in §13 as a
state only — it is not Jason's row).

### 4B. S1 — release safety

0. **The decisions move where tests can reach them.** A sourceable `scripts/lib/release_policy.sh`
   holds every shell decision S1 adds — `default_archive_path ARCHIVES_ROOT VERSION BUILD DATE`,
   `archive_plan ARCHIVES_ROOT VERSION BUILD` (what to do with existing archives of this version and
   build; `build-upload-asc.sh` passes `$HOME/Library/Developer/Xcode/Archives`, fixtures a temp dir), `allow_has CHECK` (parse
   `RELEASE_PREFLIGHT_ALLOW`), `legacy_override_refused`, `tree_is_dirty DIR` (§4B.3), `copy_scan DIR`,
   `should_push_tag MODE`; Python decisions go to `asc_policy.py`. `build-upload-asc.sh` and
   `release-preflight.sh` call them; `release-preflight.sh` honours `GATE_PROJECT_DIR` (as
   `check-warnings.sh:20` does). `test_gates.py` drives the functions directly (`bash -c 'source …; fn
   …'`) and asserts **messages, not just exit codes**. End-to-end cases copy `build-upload-asc.sh` into a
   temp tree whose `scripts/` holds stub `release-preflight.sh`, `verify-archive.sh` and
   `upload-dsyms.sh`, with stub `xcodebuild` / `git` / `security` on `PATH`, a dummy `ASC_API_KEY_PATH`
   and `CK_SKIP_SCHEMA_CHECK=yes` — so a fixture fails against the old script *for the reason under
   test*, never because a key or keychain is missing.
1. **`MANUAL` is enforced, not read back.** `asc_policy.require_manual_release(version)` (pure; raises
   `Refusal` naming the state). In `cmd_attach` and `cmd_submit` it comes **right after the `if not v: sys.exit(…)`
   exit** that follows `editable_version()`, before any write (in `cmd_submit`, followed by the
   `check-submittable` run). `create-version`
   sends `attributes.releaseType = 'MANUAL'`; when the version already exists in
   `PREPARE_FOR_SUBMISSION` with another `releaseType`, it PATCHes `MANUAL` and reads it back; in any
   other state it prints `releaseType` and writes nothing (`guard_not_in_review`, `asc.py:199-206`).
   `status` prints `releaseType`. Tests: the pure rule (MANUAL passes; `AFTER_APPROVAL`, `SCHEDULED`,
   missing → refuse); an AST test that orders calls by line and counts `post`, `patch`, `req` (non-GET),
   `cmd_cancel` and `cmd_attach` as writes — the guard precedes all of them and is a top-level statement
   of the function body (controls: move it into `else:` → fails; move it after `cmd_cancel` → fails); an
   AST test that `cmd_create_version`'s POST `attributes` hold `'releaseType': 'MANUAL'` (control: remove
   it → fails).
2. **Archives leave iCloud and are never overwritten.** Defaults are computed **after** `VERSION` /
   `BUILD` are read: `ARCHIVE_PATH = ~/Library/Developer/Xcode/Archives/<YYYY-MM-DD>/Soundpost <version>
   (<build>).xcarchive` (Xcode's Organizer location, outside `~/Documents`); `EXPORT_PATH =
   ~/Library/Caches/Soundpost-build/export/<version>-<build>/` (replaceable). Before archiving,
   `archive_plan` looks in every dated folder for `Soundpost <version> (<build>)*.xcarchive`: if one
   records a **successful** upload (`Distributions[].destination == upload` with `uploadEvent.state ==
   success`), **refuse** — in both modes (`check-build-number` refuses the upload case too; a dry run
   passes its own scratch `ARCHIVES_ROOT`, and must use an unreleased build number); otherwise write the new attempt to the next free name (`Soundpost <v> (<b>) -
   attempt <n>.xcarchive`) and leave earlier attempts untouched. Nothing deletes an archive. A dry run is
   `archive` mode; tagging exists only in `upload` mode. After a successful upload and tag, `git push
   origin <tag>`; a push failure warns, prints the command and exits 0. The existing
   `build/Soundpost.xcarchive` is not touched (D9). Update `upload-dsyms.sh`'s stale `--backfill` comment.
   Fixtures, each with a control: an archive that records a successful upload → refusal; one that records
   a failed upload → proceeds to the next name; an un-uploaded archive of
   the same build in yesterday's folder → the run proceeds to a new name and the old one is intact
   (control: a plain existence check → fails); the default resolves under
   `$HOME/Library/Developer/Xcode/Archives/`; upload mode pushes the tag once with a stub `git`, and a
   failing push still exits 0; archive mode never calls `git push`.
3. **One dirty rule; the copy scan covers what ships; overrides are named.**
   - `tree_is_dirty` = every line of `git status --porcelain --untracked-files=all` **except untracked
     (`??`) entries under `.claude/`** — used by both the preflight's clean-tree check and
     `build-upload-asc.sh`'s post-archive HEAD/clean guard. (A pathspec `':(exclude).claude'` would also
     hide *tracked* changes there; filter the `??` lines instead.) Untracked files under `.claude/`
     (other sessions' locks and worktrees, never built) do not count; a tracked change anywhere,
     including under `.claude/`, or an untracked file elsewhere, still does. Fixtures: an untracked
     `.claude/x 2.lock` → both checks pass; an untracked `Soundpost/X 2.swift` → both fail; a tracked
     `.claude/` file modified → both fail; HEAD moved during the archive → still refused (control: drop
     the filter → the first fails).
   - `copy_scan` covers the synchronized roots from `scripts/lib/project_model.py`, `*.xcodeproj`,
     `metadata/`, `scripts/`, `backend/` — each **required to exist** (a missing one, or a reader that
     errors or returns no roots, fails closed) — plus the screenshot source dir only if present; it
     prunes `.claude/`. Fixtures: a `Soundpost/X 2.swift` copy is refused (message asserted); a
     `.claude/x 2.lock` and a `.claude/worktrees/*/Soundpost/X 2.swift` are ignored; a missing required
     root fails; an absent screenshot dir passes. Copy-scan fixtures create stub `metadata/`, `scripts/`
     and `backend/` dirs in the tree, run the preflight in **`archive` mode** with
     `RELEASE_PREFLIGHT_ALLOW=keychain` (after S2.3 also the env file and a stub `xcodebuild -version`),
     and assert the copies message — so no unrelated check (clean tree, Sentry, build number) decides.
   - `RELEASE_PREFLIGHT_OVERRIDE` is **refused** with a message naming `RELEASE_PREFLIGHT_ALLOW=<check>[,
     <check>]`, whose only names are `copies`, `keychain`, `build-number`. `dirty` and `sentry` are
     refused as unknown names: both checks matter only for an upload, where the HEAD/clean guard and the
     dSYM step decide anyway. No ALLOW value touches the HEAD guard or the dSYM step.
   - In upload mode `build-upload-asc.sh` itself checks the token and runs the §4B.6 probe **before
     `xcodebuild archive`**, and later calls `upload-dsyms.sh --required`, under which a missing
     `sentry-cli` or `SENTRY_AUTH_TOKEN` exits non-zero (warn-and-skip stays for archive mode and
     `--backfill`). Fixtures: upload mode with no token → refused, and the stub `xcodebuild` was never
     called; `--required` with no
     token → non-zero; `ALLOW=sentry` / `ALLOW=dirty` / the old variable → refused.
4. **Screenshots by name.** `asc_policy.screenshot_files(names, expected)` accepts exactly the
   `NN-<screen>.png` names `screenshots.sh` produces (one shared list, or a test comparing both), refuses
   anything else by name and any missing screen; `cmd_screenshots` calls it (AST check).
5. **`asc.py check-submittable`** (GET only; calls `assert_soundpost_app()` first, as
   `check-build-number` does). For the editable version matching `MARKETING_VERSION`: build attached and
   `VALID`; `usesNonExemptEncryption` set; `releaseType == MANUAL`; `whatsNew` non-empty in en-US, ja,
   zh-Hans; per localization, every screenshot display type and its image count (a stale type is
   reported); and the age-rating declaration of the **editable app info** — `GET
   /v1/apps/{APP_ID}/appInfos`, select the one that is **not live** (pin the live state —
   `READY_FOR_DISTRIBUTION` per `RoastMate/scripts/asc_product_page.py:38-40`, confirmed by a read in S1
   and recorded in §13 — rather than guessing the editable one's states; refuse unless exactly one
   qualifies), then `GET /v1/appInfos/{appInfoId}/ageRatingDeclaration`; every null
   attribute is named, except a small tested allowlist of conditional follow-ups (e.g.
   `socialMediaAgeRestricted` after a "no", learned from the live declaration). Exit non-zero with the
   list; `cmd_submit` runs it after the MANUAL guard and refuses on any item. Policy tests: two app infos
   listed **live first** (live complete, editable with one null) → the null is reported (control: pick
   the first app info → fails); a display type this release did not upload → reported.
6. **The Sentry token is proven, the venv is durable.** Upload mode probes an endpoint the upload itself
   depends on (the organization's chunk-upload options, which `debug-files upload` requests first):
   `401` is fatal ("token rejected"); `403` and network errors warn (the upload step stays fatal). §13
   records the token's type and scopes, never its value. `ASC_PYTHON` defaults to
   `~/Library/Caches/Soundpost-build/asc-venv/bin/python3` (with a `.no-sweep` file so the daily job
   keeps it, and a printed one-line rebuild command); `/tmp` stays a fallback. Fixtures with a stub:
   401 → refuse; 403 → warn (control: 403 fatal → the 403 fixture fails).
7. **How screenshots reach the store — settled read-only, before any upload.** From Apple's current App
   Store Connect API documentation and `RoastMate/scripts/asc_product_page.py`: (a) whether uploads go
   through App Asset Library placements or the legacy `appScreenshotSets`; (b) how an inherited set of
   another display type is removed from a new version; (c) whether `DELETE /v1/appScreenshots/{id}` can
   remove an image the live version still shows; (d) the display-type name and accepted sizes for
   1320×2868 (expected `APP_IPHONE_67`). Record the answers with links in §13 and pin (d) in `asc_policy`
   as one constant (type and pixel size) that `asc.py` and `screenshots.sh` both read. **Until (c) is
   settled, `cmd_screenshots` refuses to delete anything** (a policy test). If the stale 6.5-inch set
   cannot be removed safely by the API, Jason removes it in the web UI before submit (H5).
8. **Measurement (D5).** `asc.py analytics-request` (one `POST /v1/analyticsReportRequests`, `accessType
   ONGOING`; refuses if one exists) — **sent only after Jason says yes to D5 in chat**, or he runs the
   printed command himself; S1 so that weeks of reports exist before 1.13.0's listing. `asc.py analytics`
   (GET only) lists reports and downloads the App Store Discovery & Engagement and App Downloads
   instances to `~/Library/Caches/Soundpost-build/analytics/` (never `~/Documents`), printing a weekly
   table (impressions, product-page views, conversion, first-time downloads by source). Tests pin the
   request to one POST with refuse-if-exists, and `analytics` to GET.

### 4C. S2 — CI on the shipping toolchain

1. **Verify before writing.** Read GitHub's runner-images README / changelog for the `xcode-27` image
   (label, architecture, the Xcode list, the default Xcode, the iOS 27.x runtimes and their device
   types). Record what was read, with the URL, in §13. If no such image exists, stop S2.2, S2.3's CI half and
   S2.6, keep the local clean gate, and reword §0 per §2; `release-toolchain.env` still exists, pinned to
   the local build, and the preflight and `verify-archive.sh` still read it.
2. **A second job, `test-xcode27`**, on that image, running **every step of the 26.6 job** — including
   "Release-tooling policy tests" and "CloudKit seed coverage" — except the delivery-server tests (moved
   to S2.5). `DEVELOPER_DIR=/Applications/Xcode_27.2.app`, `EXPECTED_XCODE "Xcode 27.2"` asserted exactly
   as today. `MIN_TESTS` moves to workflow-level `env:` (one value for both jobs), and a new
   `MIN_PY_TESTS` (78 today) is checked against the Python step's `Ran N`, raised with S1/S2's fixtures.
   The Swift package cache key already includes the Xcode, so the first run resolves cold. The 26.6 job
   stays until D23. **Control:** a deliberate Xcode-27-only warning (drop the `StoreKit` import that
   `ContentView.swift:3-5` exists for), pushed as a pull request from a throwaway branch (never to
   master), turns the new job red while the 26.6 job stays green; close the PR and delete the branch (it
   is the agent's own).
3. **The release refuses an untested toolchain.** One file, `scripts/release-toolchain.env`
   (`EXPECTED_RELEASE_XCODE_BUILD=27B52`, `MIN_SDK=iphoneos26`), read **by the `test-xcode27` job only**
   (its `xcodebuild -version` build must equal it; the 26.6 job keeps asserting only `EXPECTED_XCODE`),
   by the preflight **before archiving** (the local `xcodebuild -version` build must equal it; on a
   mismatch it refuses at once and prints the two ways out — install the pinned Xcode side by side and
   set `DEVELOPER_DIR`, or bump the pin in a commit whose CI ran on the new build), and by
   `verify-archive.sh` (fatal): the app's **and each appex's** `DTXcodeBuild` must equal it and
   `DTSDKName` must be ≥ the minimum; both values are printed into the release log. The env file's value
   must match `^[0-9]{2}[A-Z][0-9]+[a-z]?$`. `verify-archive.sh` reads the file from `GATE_PROJECT_DIR`
   so fixtures supply their own. **`ArchiveTests` changes:** `setUp()` writes a default
   `scripts/release-toolchain.env` (`EXPECTED_RELEASE_XCODE_BUILD=27B52`, `MIN_SDK=iphoneos26`) into the
   tree, and `archive()`'s good fixture writes `DTXcodeBuild: "27B52"` and `DTSDKName: "iphoneos27.2"`
   into both plists **as literals** (never read from the env file); the missing / empty fixtures delete
   or empty that file. New fixtures: env file missing or empty → fatal; a key absent from either plist →
   fatal; the app matches but the appex differs → fatal; an SDK below the minimum → fatal; each with a
   control.
4. **A tested simulator picker.** `scripts/ci/pick_simulator.py <name> <min-major>`, used by both macOS
   jobs, picks the named device on the newest runtime that offers it and exits non-zero if none does.
   Each job passes its own arguments, chosen in S2.1 from that image's runtime table and recorded in §13
   (e.g. `test-xcode27`: `"iPhone 17" 27`; the 26.6 job: a device its iOS 26.x runtime offers, `26`).
   `test_gates.py` feeds it `simctl` JSON: (a) iOS 27.2 with only `iPhone Duo` plus iOS 27.0 with `iPhone
   17` → 27.0's `iPhone 17`; (b) `iPhone Duo` only → non-zero with a message (control: the old
   first-iPhone rule picks Duo in (a)). Each job selects at its start, `simctl boot`s in the background,
   passes the UDID through step outputs and runs `simctl bootstatus -b` before `xcodebuild test`;
   `timeout-minutes: 45`.
5. **The delivery server's tests run on CI.** A `server` job on `ubuntu-latest`: a failed Deno install
   or `deno cache` is an **error**; the job parses `deno test`'s passed count and fails below a floor
   (today's count); `backend/supabase/tests/run-local.sh` runs against Ubuntu's PostgreSQL and its `ALL
   PASS` marker is required. The macOS step is removed only after three pushes whose logs show both
   counts. If `run-local.sh` needs Linux paths or stubs, change the script, not the test.
6. **W7 — the control's intent runs only in the app on iOS 27** (`allowedExecutionTargets = .main`, a
   test under `if #available(iOS 27.0, *)`) needs the iOS 27 SDK on every CI job, because the shared file
   forbids `#if`. Default (D23): **retire the 26.6 job after the 27.2 job has been green on five pushes
   with its logs showing both test counts, and S2.5's three-push condition holds** (or, if S2.5 was
   dropped, the 27.2 job runs the delivery-server step) — the shipped binary is built with 27.2, and the
   App Store minimum is met — then land W7 with its control (`.default` → test fails). Ordering with
   S6: §5.

### 4D. S3 — the store stays where it is

1. `SoundpostModelContainer` gains `static func onDiskConfiguration(cloudKit:) -> ModelConfiguration {
   ModelConfiguration(schema: productionSchema, groupContainer: .none, cloudKitDatabase: cloudKit) }`,
   used by rungs 1 (`.automatic`) and 2 (`.none`). Name, default-URL flag and CloudKit settings are
   unchanged; rung 3 (in-memory) and every test / DEBUG container are untouched.
2. **`StoreLocationTests`:**
   (a) `onDiskConfiguration(cloudKit: .automatic).url` and `(.none).url` each equal
   `URL.applicationSupportDirectory.appending(path: "default.store")` — a literal path built
   independently of `ModelConfiguration`, so the test cannot compare a URL with itself;
   (b) each equals the URL of today's unpinned `ModelConfiguration(schema:cloudKitDatabase:)` in the test
   host (which has no App Group) — the no-op proof for existing installs;
   (c) a source census over the shipping sources: both on-disk rungs call `onDiskConfiguration`, exactly
   two call sites, and no other `ModelConfiguration(` in `Soundpost/` (non-test) is on-disk without
   `groupContainer: .none`; the census proves it found `SoundpostModelContainer.swift` (`#require`).
   Controls: (1) drop `groupContainer: .none` → (c) fails; (2) pass `.identifier("group.x")` → (a) should
   fail, but in a test host with no App Group SwiftData may fall back to the default location — if (a)
   passes, (c) is the assertion that catches it, and §13 says so; (3) change the store name → (a) and (b)
   fail. Record which assertion caught which control.
3. **Optional witness, disk-gated (S6, with H2):** scratch builds signed ad-hoc with CI's no-signing settings
   (`CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""`,
   `ci.yml:207-208`) and `CODE_SIGN_ENTITLEMENTS` pointing at a scratchpad copy that adds
   `group.com.soundpost.Soundpost` — so the entitlement can never reach automatic signing or the developer
   portal; never committed on the iOS 27 simulator: (A) unpinned + group,
   (B) pinned + group, each over a library with one capsule with audio. Record the resolved store path,
   whether "Moved default store into new location" is logged, and whether the library and its audio
   survive. If (A) shows no move, record "inconclusive on the simulator" — the M24 widget build must still
   pass an entitlement-present upgrade test on a device (TestFlight, D8). Evidence for M24, not a gate.

### 4E. S4 — doors people can find

1. **"Ways to start a capsule"** — a Settings section placed **before About**:
   - `@AppStorage("settings.showsSiriTip") private var showsSiriTip = true` and
     `SiriTipView(intent: OpenCaptureIntent(), isVisible: $showsSiriTip)` — the system draws the phrase
     from the shipped App Shortcut; the section does not paraphrase it. A dismissed tip stays dismissed (a
     tip that reappears is a nag — rule 2); if dismissal leaves an empty row, wrap it in `if showsSiriTip`.
   - `ShortcutsLink()` — opens the Shortcuts app on Soundpost's actions.
   - Two static lines: "Add the “New capsule” widget to your Home Screen." and, inside `if #available(iOS
     18.0, *)`, "Add “New capsule” to Control Center." Under them (not under the Shortcuts link), the
     existing key "Opens Soundpost ready to record. Recording starts only when you tap." — no new
     translation. **The widget line names the Lock Screen** (「ロック画面」/「锁屏」, the catalog's existing terms) **only after**
     S6 or H4 has recorded, in §13, a Lock Screen face added and tapped. JA / ZH drafted from the existing
     catalog terms (新しいカプセル / 新建胶囊) and reviewed by hand against §1.1 and the store gate's
     off-sale terms (§1.3), recorded in §13. Widgets appear in the iOS 18 gallery only after the first
     launch (M22 §13 S5) — the person reads this line inside the app, so it is true.
   - **Guards** (over `CaptureDoorTests.shippingSources()`, in `CaptureDoorTests` beside the censuses at
     `:150-171`): exactly one call site each of `SiriTipView(` and `ShortcutsLink(`, both in
     `Soundpost/Views/SettingsView.swift`, the section before About's; the `SiriTipView(` passes
     `isVisible: $` bound to an `@AppStorage` property; the intent is constructed there, never
     `perform()`ed, and the `requestCapture` census still counts one site; `OpenCaptureIntent.swift`'s
     SHA test unchanged; localization 100%. Controls: delete the section → the census fails; move
     `ShortcutsLink()` into `ContentView` → fails; drop `isVisible:` → fails; delete a JA string → the
     localization gate fails.
2. **(D17, default yes) passive About rows:** `ShareLink("Share Soundpost", item: appStoreURL)` and
   `Link("Rate Soundpost", destination: appStoreURL.appending(queryItems: [URLQueryItem(name: "action",
   value: "write-review")]))`, one `appStoreURL` constant (`https://apps.apple.com/app/id6778389097`).
   They never present themselves. Census: exactly one `ShareLink(` and one "Rate Soundpost" site, both in
   `SettingsView.swift` (control: delete them → fails). If Jason says no, skip.
3. **Widget pins and VoiceOver** (`SoundpostTests/WidgetExtensionTests.swift`, exact-text pins in the
   file's comment-stripped style):
   - `theLauncherIsDisfavouredOnlyOnCarPlayAndMac` — the iOS 26 branch returns exactly `[.carPlay,
     .iPhoneWidgetsOnMac]`, the fallback `[.iPhoneWidgetsOnMac]`, applied with
     `.disfavoredLocations(Self.disfavored, for: [.systemSmall])` (control: drop `.carPlay` → fails);
   - `everyGlyphIsAccentableAndTheCircleHasItsBackground` — each `Image(systemName: "waveform")` is
     followed by `.widgetAccentable()` before the next view initialiser (control: move one onto the
     `Text` → fails); `AccessoryWidgetBackground()` once, inside `.accessoryCircular`;
   - `theFaceReadsNothingFromTheTimeline` — the exact text `provider: LauncherProvider()) { _ in` …
     `LauncherView()` …, and `LauncherView` declares no stored property besides
     `@Environment(\.widgetFamily)` (control: `{ e in LauncherView(stamp: e.date) }` → fails);
   - **VoiceOver:** move `.accessibilityElement(children: .ignore)` + `.accessibilityLabel("New
     capsule")` from the circular case to `face` in `body` (before `.widgetURL`), so every family reads
     as one element "New capsule" (no new string); `everyFaceReadsAsOneNewCapsule` pins both modifiers on
     `face` and none inside the switch (control: move them back → fails). Witness with Accessibility
     Inspector in S6 on the build that has it (the small face; other faces as reachable); the "before"
     state is established from source (§3.5).
4. **(Optional, timeboxed 1 hour) RenderPreview spike for the Lock Screen faces.** Add
   `#Preview(as: .accessoryCircular)`, `(as: .accessoryRectangular)` and `(as: .systemSmall)` to
   `LauncherWidget.swift` (no new file — `theExtensionHoldsExactlyItsFiles` unchanged); try Xcode 27.2's
   headless `xcrun mcp-server` RenderPreview on that file; save PNGs to `docs/evidence/m23-widget/`. A
   rendered preview is **not** a Lock Screen witness (it shows how the face draws, not that it can be
   added and tapped); if the tool cannot render widget previews, record that and move on.
5. **(D16, default no) Free image share.** If Jason reverses `ProGate.swift:126-131` for images only:
   split `canExport` into `canShareImage` (always true) and `canExportVideo` (`isPro`); the detail screen
   shows "Share" for the existing image + `.m4a` payload; video stays behind `canExportVideo` and is never
   teased (ProOffer rules unchanged). Tests: the split, `VideoExportPolicy` still `.needsPro` for free
   users, a census that the free path never opens `ProPaywallView`; a listing line and store-gate claim
   only then. Not built unless D16 = yes.

### 4F. S5 — delivery, app-only

1. **The re-seal orphan, and a far seal's queued cancel.**
   - A testable `CapsuleActions.seal` (mirroring `CapsuleActions.delete`) that the detail screen calls
     instead of `store.commitSeal(`: if the capsule carries `serverJobSyncedAt` before the seal, enqueue a
     durable pending cancel **before** the save; on a failed save, resolve only the entry this call added.
     Not inside `seal()` (M22 review L-D3).
   - A testable `CapsuleActions.normalizeAndRefresh(in:now:)` that replaces `refreshAndSync`'s three
     lines (`ContentView.swift:608-610`) in the same order: it **records the ids of `.sealed` capsules
     with `serverJobSyncedAt != nil` before** calling `store.normalizeSealHours()` (which clears the
     stamp, `CapsuleStore.swift:375`), enqueues a cancel for each of those that comes back moved, calls
     `store.refreshDueSeals()` as today, then makes **one** save in `do/catch` that, on failure, resolves
     only the entries it added (so due seals flipped to `.resurfaced` are saved exactly as today).
     `CapsuleStore.normalizeSealHours` and `refreshDueSeals` are unchanged.
   - **The drain resolves a stored far seal's entry without cancelling only when the capsule is
     stamped** (the server has confirmed exactly this seal). An unstamped far seal's entry stays queued,
     sending nothing, until the diff stamps it; it is cancelled if the seal turns near or the capsule is
     gone first. Existing tests that resolve a stamped survivor
     (`aQueuedCancelForACapsuleStillInTheStoreCancelsNothing`) are unaffected.
   - **Pins rewritten / added:** `WriteFailureViewGuardTests.swift:18-24` and `CaptureSealTests.swift:171`
     now pin `CapsuleActions.seal(` with the instant computed after `requestAuthorization()` (keeping the
     catch-body checks); a pin that the detail seal calls `CapsuleActions.seal(`; a census that
     `commitSeal(` has exactly one shipping call site, inside `CapsuleActions`; a pin that `refreshAndSync`
     calls `CapsuleActions.normalizeAndRefresh(` with `drainCaptureRequest()` still before its first
     `await`.
   - **Tests** (`withIsolatedDeliveryPreferences`, the held `SpyDeliveryBackend`), each with a control:
     (1) offline unseal → re-seal(near) → one cancel reaches the backend on the next drain (control: skip
     the enqueue → fails); (2) offline unseal → re-seal(far) with the backend throwing → the entry is
     still queued after the reconcile; then the seal moves inside the horizon → one cancel (control:
     restore the unconditional far resolve → fails); (3) sealing an unstamped capsule, near and far,
     queues nothing and sends no cancel (control: enqueue unconditionally → the near case records one
     cancel); (4a) a failed save removes the entry this call added; (4b) an entry queued before the call
     survives it (control: resolve on every failure → (4b) fails); (5) normalize moving a stamped seal
     inside the horizon queues one cancel (control: read the stamps after the store call → fails).
2. **A content-free failure reason (prepared by the agent, deployed by Jason).** `apns.ts`'s retry
   outcome carries the APNs `reason` (content-free, per its own comment at `:147-150`); `index.ts` keeps
   a `DispatchOutcome[]`, passes `.status` to `decideSettlement` and the whole array to a pure
   `state.ts` `retryLabel(outcomes)` → e.g. `dispatch_failed:http_403:InvalidProviderToken` (a network
   error → `network`); both the retry and dead-letter branches pass the label as `p_error` (truncated to
   200 by `mark_job_retry`) and log `dispatch_rejected` — APNs reasons carry no content (`index.ts:16`).
   Deno tests drive `apns.ts` itself: the exported dispatch function with a stubbed `fetch` answering
   403 `{"reason":"InvalidProviderToken"}`, its outcome fed to `retryLabel` → that label (a test that
   feeds `retryLabel` a hand-made outcome cannot see `apns.ts`; control: `apns.ts` drops the reason →
   fails). **Jason deploys** (the agent prepares the exact `supabase functions deploy` command and the
   before/after reads) **only if S0 does not reach `sent`**, or after S0 passes — never during an S0
   window. The deploy also carries the undeployed `apns.ts:134` fix.
3. **B2 (D11) — only if, when S5 starts, S0 has shown `sent`, D3 is applied and Jason said yes.** In
   `SealDeliveryService.reconcile`'s cancel loop and `drainPendingCancels`' stored case, do not cancel a
   capsule that is stamped and still `.sealed` with a `sealUntil` (every change to a seal clears the
   stamp, so a stamp means "the server holds exactly this seal"); unseal, resurface/open and delete still
   cancel. `NotificationPlanner.swift:59` skips a stamped seal only while `due - now > localHorizon`.
   Rewrite `DeliveredOnTheDayTests:75-92` to expect no cancel, the stamp kept and a local request
   present. Known cost, stated to Jason with D11: every device that synced in the last day shows two
   banners (the local one at 09:00 and the push about a minute later; foreground de-duplication only).
   Otherwise B2 moves to M24 unchanged.

### 4G. S6 — the witness pass (one boot per device)

Precondition: ≥ 30 GB free, or Jason's explicit exception for this pass (H2); with D23 = yes, W7 has
landed (§5). Debug build of HEAD once S5 and (with D23 = yes) W7 have landed, through the shared package
helper; `/tmp/lock-<slug>`; UDIDs
from `xcrun simctl list devices available -j` (exact name and runtime, exactly one match); simulator
language and text size restored after.

- **`iPhone 17 Pro` (iOS 27):** the Settings section in EN, JA, ZH (screenshots; Siri tip text as the
  system draws it; the Shortcuts link opens Shortcuts); **dismiss the tip, leave Settings, relaunch →
  the tip is gone and no empty row remains**; the widget at `accessibility-extra-extra-extra-large`; dark,
  tinted and clear Home Screens; **warm and cold control taps** (app backgrounded, not recording) →
  capture idle; a widget tap during a take → the take goes to review, nothing lost; Accessibility
  Inspector on the small widget (S4.3); the Lock Screen attempt — `LOCK`, wake, a
  stationary `touch_path` hold (4 samples, `dt_ms` 1000) at mid-screen; if Customize opens, add both
  accessory faces, tap one, unlock, expect capture idle (that is a Lock Screen witness); if not, record
  the exact attempt. Optional S3.3 witness.
- **`Soundpost-iOS18` (iOS 18.5):** the Settings section in EN, JA and ZH-Hans (one boot; relaunch per
  language); the tip dismissal; warm and cold control taps.
- **`iPhone 17 Pro Max` (iOS 27) — screenshots v2:** `screenshots.sh` uses this listed device by UDID
  under `/tmp/lock-iphone-17-pro-max` (it no longer creates `Soundpost-Shots`), writes to
  `~/Library/Caches/Soundpost-build/screenshots-69/<locale>/` (outside iCloud, with a `.no-sweep` file;
  `asc.py` reads the same constant) and **never touches `build/screenshots/`** — its `rm -rf` of a
  locale folder (`screenshots.sh:132`) would otherwise wipe the set the store shows today, and deletions
  in `build/` are Jason's (D9); defines its helpers
  before use, checks the size from the `asc_policy` constant (§4B.7), sets `simctl status_bar … override
  --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4` and clears it at
  exit, and seeds the demo library with fixed daytime clock times. **A doors shot** is taken only if it
  can be framed without the iCloud row: a DEBUG staging case `-screenshotScreen doors` (inside the
  existing `#if DEBUG` hook) opens Settings and scrolls the doors section to the top
  (`ScrollViewReader.scrollTo(_, anchor: .top)`); `doors` joins `SCREENS` and the header comment;
  §13 records, per locale, that no iCloud row is in frame — otherwise the doors shot is dropped. Never
  sign the capture simulator into iCloud and never alter the row. The doors shot is captured after the
  Lock Screen wording is decided. Captions: none unless Jason says otherwise (D18; M19 §4A rule 3).

Every witness is recorded in §13 with what was tapped and what opened. The device-only checks (H4) are
Jason's.

### 4H. S7 — the release: 1.13.0, build 25

**Preconditions:** 1.12.0 **released** (H1); S1–S6 done (or dropped per §2); the Lock Screen question
answered — S6 reached Customize and a tap opened capture idle, or H4's answer is recorded, or neither (then
the "remove" branch below); §4B.7's screenshot answers recorded; the local Xcode build equals
`release-toolchain.env` (§4C.3).

- **Lock Screen.** With no Lock Screen witness, "Lock Screen" is removed from the doors line in
  `metadata/*/description.txt:13` (all three locales; the store gate's `widget` claim still passes) and
  pushed with `asc.py description`; the 1.13.0 notes and the S4.1 line do not mention it.
- **Promotional text (D6) — the exact three texts Jason approves** (152 / 69 / 49 characters, ≤ 170).
  A new store-gate check, **limited to `promotional_text.txt`** (the description's existing
  "offline-first" / 「オフライン優先」/「离线优先」 at `description.txt:19` is unchanged and not covered by
  it), refuses EN "offline" except as "works offline", JA「オフライン」except「オフラインでも使え」, ZH
  「离线」except「离线也能用」; it lands in the same commit as the new texts, with a fixture: the M8 text
  passes the old gate and fails the new one:
  - EN: "Capture how a moment actually sounds — keep it as a mood-tinted waveform card, and seal it to
    open again on a future day. Private, and it works offline."
  - JA: 「その瞬間の「音」を残そう。気分で色づく波形カードになり、未来の日付まで封印して開くこともできます。プライベートで、オフラインでも使えます。」
  - ZH: 「留住一个瞬间真实的声音。它会化作随心情上色的波形卡片，还能封存到未来某天再开启。私密，离线也能用。」
  `asc.py promo` writes only `promotionalText` from `metadata/*/promotional_text.txt` to the
  `READY_FOR_SALE` version and, if present, the editable one; an AST test pins that its only PATCH
  carries exactly the `promotionalText` key built by the policy function (control: add a second
  attribute → fails); it reads back each value.
  Run **only after Jason approves these three texts in chat**; the read-back is recorded in §13.
- **Copy:** `MARKETING_VERSION 1.13.0`, `CURRENT_PROJECT_VERSION 25`; `release_notes-1.13.0.txt` in three
  languages, and `release_notes.txt` made identical to it in each locale (the store gate requires the
  pair to match, and `asc.py notes` pushes `release_notes.txt` — `check-store-metadata.py:152-156`,
  `asc.py:287-289`) (the Settings section; the widget reads as one VoiceOver element — only for the faces
  checked); JA / ZH keywords filled with literal terms only (drafts: ja
  `,録音,音声日記,自然音,雨音,声の記録` — no ライフログ, which suggests continuous logging when the app
  records only on a tap; zh `,录音,时光胶囊,自然声音,雨声,声音收藏,留声`; ≤ 100; no competitor names; nothing off sale; the store gate enforces length and blocked words).
- **Screenshots:** upload the 6.9-inch set by the path §4B.7 settled; after it verifies, the stale
  `APP_IPHONE_65` set leaves 1.13.0 by the API path §4B.7 proved safe, or by Jason in the web UI (H5);
  `check-submittable` shows one iPhone display type per locale before submit.
- **Upload and submit** with the S1 tools: preflight (no override), `build-upload-asc.sh` (archive to
  Xcode's Archives, toolchain pin, `--required` dSYMs, tag push), `create-version 1.13.0` (MANUAL),
  notes, keywords, description if changed, screenshots, `attach 25`, `check-submittable`, `submit`.
  **STOP** and tell Jason; `asc.py release` only on his explicit word. Never `asc.py resubmit` after a
  rejection without reading M19 §8-iii.

---

## 5. Work breakdown

1. **S0** whenever Jason starts it; it gates only D11 / B2 and the S5.2 deploy. If S0 ends
   `dispatch_failed` or keeps retrying, S5.2 moves ahead of S2–S4.
2. **S1 → S2 → S3 → S4 → S5 → S6 → S7.** S1 first: every later release step uses its tools (and D5's
   POST, on Jason's yes, starts the analytics baseline). S2 before S3–S5 so they are tested on both
   toolchains. S3, S4, S5 are independent of each other.
3. **S6 ordering.** With D23 = yes, S6 starts only after W7 has landed (five green 27.2 pushes counted
   from S2). If S6's warm control tap fails and W7 has not landed (D23 = no), W7 is not landed against
   Jason's answer: 1.13.0 ships the control unchanged, the failure is recorded, and both the listing's
   Control Center claim and the in-app line "Add “New capsule” to Control Center." are reviewed under rule
   1 with Jason. If the warm tap fails **with** W7 landed, W7 did not fix it: record it, take both claims to
   Jason the same way, and investigate before S7. If W7 lands after S6 for any reason, a short second
   pass (warm and cold control taps only, `iPhone 17 Pro` and `Soundpost-iOS18`) runs before S7 — H2
   covers it.
4. **S7** needs S6, 1.12.0 released (H1), the Lock Screen answer, §4B.7's screenshot answers and the
   pinned Xcode.
5. If H2 is not available when S6 comes up, S6 waits and S7 waits with it; nothing in S1–S5 waits.

---

## 6. Privacy / legal delta

- The Settings section and About rows show nothing about the user; `SiriTipView` / `ShortcutsLink` are
  system views; `ShareLink` shares only the App Store URL. No new data is read, stored or sent.
- The store pin changes no data and no location: shown by S3's test on the iOS 26.x / 27.x simulators;
  iOS 18 by reading the 18.5 SwiftData binary (§3.4); iOS 17 untested (D22). Optional S3.3 builds use an
  ad-hoc App Group entitlement in scratch builds on a simulator only; nothing ships with it.
- S5.1 sends the server **fewer** stale jobs (it cancels an orphan); S5.2's reason strings are APNs
  status codes and reason names, no user content.
- `asc.py analytics` downloads aggregated, Apple-thresholded reports to a local cache outside iCloud.
- **§13 is public:** production reads appear only as Jason's own rows (job id, 8-character prefix) or
  counts and states; the analytics baseline is recorded only as Jason decides.
- **App Privacy label and privacy policy unchanged by M23.** M21 D7 (Sentry's city-level geo vs a label
  that declares no location) is still open (D7).
- Promotional text and keywords are claims: every one literal; "offline" corrected (§3.7).

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `releaseType` cannot be set on create | PATCH in `PREPARE_FOR_SUBMISSION`, then read back; the guard still refuses attach/submit |
| A tooling fixture fails against the old script for an unrelated reason | extracted `release_policy.sh` / `asc_policy`; stubbed end-to-end tree; messages asserted (§4B.0) |
| A failed upload leaves an archive that blocks the retry | never refuse on mere existence; an un-uploaded attempt gets the next name; only an uploaded build is refused |
| The narrowed copy scan misses a copy that compiles | roots from the project reader, required to exist; a source-root copy fixture must fail |
| The dirty rule hides a real change | only untracked paths under `.claude/` are excluded; tracked changes and other untracked files still fail |
| An upload ships without dSYMs in Sentry | `upload-dsyms.sh --required` in upload mode; no ALLOW name for it |
| The `xcode-27` image is not what the grounding reported, or its default changes | S2.1 reads it first; `EXPECTED_XCODE` and the toolchain file asserted; tested simulator picker |
| Xcode auto-updates before S7 | the preflight compares builds before archiving and prints the two ways out; H6 |
| Retiring the 26.6 job hides a regression on an SDK users never get | shipped binaries are 27.2-built; App Store minimum met; the 27.2 job runs every gate; D23 is Jason's to overturn |
| `groupContainer: .none` resolves somewhere else on some OS | literal-path test on CI's 26.x / 27.x and locally on 27; iOS 17 untested, as in M22 |
| The Settings section reads as a prompt | inside Settings only; tip dismissal persisted and witnessed; exactly-one census |
| A screenshot DELETE removes an image the live version shows | §4B.7 settles it read-only first; no delete until then; H5 fallback |
| The stale 6.5-inch set stays on 1.13.0 | §4B.7 / H5; `check-submittable` reports display types |
| The orphan fix cancels a job it should keep | the drain decides by a fresh fetch; far re-seal resolves only once stamped; tests (2)–(4b) |
| Disk stays under 30 GB | S6 batches all witnesses into one boot per device and waits for H2 |
| Machine load makes local runs flaky | CI is the authority; known local-only flake `VideoGateTests.playbackStaysFree` |
| 1.12.0 rejected or withdrawn | thread-keeping path (memory `soundpost-1-9-0-rejected-pro-hidden`); never `resubmit` blind; a withdrawal stops S7 for a separate plan (H1) |

---
## 8. Human-in-the-loop (needs Jason)

**A bold default below is the plan's assumption for building. It is never consent for an App Store
Connect write outside the release path (D5's POST, D6's push), a production Supabase change (S0 Option
A, D3, S5.2's deploy), or a move in `build/` (D9). Each of those happens only on Jason's explicit word
for that action, recorded in §13.**

**Steps**
- **S0** push witness (§4A) — Option A needs one production `UPDATE`, run by Jason.
- **H1 — 1.12.0:** release on your word after approval. S7 waits for it. If you would rather withdraw
  1.12.0, S7 stops for a separate plan: the withdrawn record would be renamed 1.13.0 (as 1.0 → 1.1.0
  was), `create-version` skipped, and 1.12.0's widget line carried into the 1.13.0 notes — without
  "Lock Screen" unless S6 or H4 saw it.
- **H2 — disk for S6:** 19–21 GB free; the global rule forbids a simulator boot under 30 GB. Free space,
  or grant an exception for one batched pass (three devices; afterwards `Soundpost-iOS18` is shut down,
  and `iPhone 17 Pro Max` too if it was not already booted — the shared `iPhone 17 Pro` stays booted)
  and, if needed, a short
  second pass for the control taps (§5.3).
- **H3 — the missing 1.12.0 app bundle (§3.8):** did you move `Soundpost.app` out of
  `build/Soundpost.xcarchive` around 20:46 on 2026-11-10? If you have it, put it back or into the copy in
  Xcode's Archives; if not, nothing user-facing is lost (App Store Connect has the binary, Sentry has the
  dSYMs).
- **H4 — ten minutes on your phone** (TestFlight if D8 = yes, else once 1.12.0 is live): add the circular
  and rectangular widgets to the Lock Screen and tap each while locked (expect unlock, then capture
  idle); put the control in a Lock Screen slot and tap it locked; if your phone has an Action Button,
  Settings › Action Button › Controls › "New capsule", press it; StandBy with the small widget by day and
  at night; a tinted Home Screen. The agent sends a checklist and records the answers; the control's doc
  comment and any copy then state only what was seen.
- **H5 — the old screenshots, if the API cannot remove them safely (§4B.7):** delete 1.13.0's
  `APP_IPHONE_65` set in the App Store Connect web UI before submit.
- **H6 — keep Xcode 27.2 (27B52) until 1.13.0 is uploaded:** turn off App Store auto-update for Xcode, or
  keep a side-by-side `Xcode-27.2.app` (the preflight refuses a different build).
- **S7** "release" — the only public, irreversible action.

**Decisions** (M23 assumes the default in **bold** for building; see the line above)
- **D1 Pro:** **keep hidden** — settled (§1.3); not re-asked.
- **D3 apply `0003_m21_hygiene.sql`:** **yes, you apply it, after the agent re-runs the local test**
  (independent of S0).
- **D5 analytics report request:** **yes, on your word** — after you say yes in chat, the agent sends the
  one POST in S1 (or you run the printed `asc.py analytics-request`).
- **D6 promotional text:** **push the three texts in §4H** after you approve them in chat.
- **D7 Sentry city-level geo off:** your go-ahead (and the setting in Sentry's UI if the token cannot).
- **D8 TestFlight internal group (you as tester):** **yes** — you create it; it makes H4 possible before a
  release.
- **D9 (rest) repo hygiene — deletions and moves are yours:** `build/` holds 208 MB in iCloud, including
  seven old release archives (`Soundpost 3–9.xcarchive` = 1.4.0 (8) … 1.9.0 (18)) — **move them to
  Xcode's Archives, don't trash them**; `.git/index 2` (2026-06-18); branches `release/1.6.1`,
  `release/1.6.2` (local and remote), remote `chore/build-roots-2026-10-15`; worktree
  `claude/dazzling-satoshi-fb69f2` (a superseded WIP dSYM commit). The agent lists each with a
  recommendation; nothing moves without your word.
- **D11 B2 (multi-device last day):** **only if S0 shows `sent` and D3 is applied**; otherwise M24.
- **D15 S0 option:** **A** (one `UPDATE`, minutes; does not witness the reveal) / B (no write; no
  Soundpost on any device for the 24 hours before the seal's 09:00; witnesses the reveal).
- **D16 free image share:** **no change in M23** (a monetization reversal that cannot be taken back); say
  yes and it is a small S4 item (§4E.5).
- **D17 passive "Share Soundpost" / "Rate Soundpost" rows in About:** **yes** (passive rows, not
  prompts); say no and they are skipped.
- **D18 screenshots:** **6.9-inch on the shared iPhone 17 Pro Max, no captions, the old 6.5-inch set
  removed** (one iPhone display type per locale; captions only if you ask).
- **D19 JA / ZH subtitles and the JA name:** **unchanged**; the agent drafts options if you want them
  (app-level fields you set in App Store Connect).
- **D20 a New Year's Eve in-app event:** **no** (it would need App Review and could not promise a push a
  year later while S0 is unwitnessed); decide by ~2026-12-10 if you want it.
- **D21 StandBy:** **keep the widget suggested there** (unchanged).
- **D22 iOS 17:** **keep 17.0 as the floor, untested** (no runtime; installing one is your call).
- **D23 CI toolchain:** **retire the Xcode 26.6 job after the 27.2 job is green on five pushes** — the
  shipped binary is 27.2-built — then W7 lands. Say no and W7 waits.

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| Policy tests for release tooling | `scripts/test_asc_policy.py`, `asc_policy.py` (`Refusal`, `reusable_draft`, `draft_items_plan`) |
| Gate fixtures, a project reader | `scripts/test_gates.py` (`ArchiveTests` helpers), `scripts/lib/project_model.py` (M22 S1) |
| Archive checks | `scripts/verify-archive.sh` (fatal, M22) |
| A read that checks the app first | `asc.py` `check-build-number` (`:599-607`) |
| Which app info / screenshot path | `RoastMate/scripts/asc_product_page.py` (two app infos; asset library note — verify) |
| A delete path with a durable cancel | `CapsuleActions.delete`, `drainPendingCancels`, `SpyDeliveryBackend`, `HoldingCenter` |
| Isolated preferences in tests | `withIsolatedDeliveryPreferences`, `TestSupport.withIsolatedListening` |
| Door censuses and the intent pin | `CaptureDoorTests` (`shippingSources()`, `callSites`, SHA of `OpenCaptureIntent.swift`) |
| Widget source guards | `WidgetExtensionTests` (comment-stripped scans) |
| The door qualifier, translated | "Opens Soundpost ready to record. Recording starts only when you tap." |
| Translated terms | "New capsule" 新しいカプセル / 新建胶囊; About 情報 / 关于 |
| Mutation harness | `scratchpad/mutate.py` pattern (M20–M22 §13) |
| Screenshot capture | `scripts/screenshots.sh` (M19 §4A lessons), the `-screenshotScreen` hook |

---

## 10. Acceptance criteria

- §0 success list holds; every simulator witness is recorded in §13 with what was tapped and what
  opened; H4's answers recorded when Jason gives them.
- Every new test has a recorded control mutation that made it fail; every gate or tooling change has a
  `test_gates.py` / `test_asc_policy.py` fixture that the old code passes for the reason under test and
  the new code fails.
- CI green on the final commit on every job; `MIN_TESTS` and `MIN_PY_TESTS` ≥ the final counts.
- 1.13.0 submitted through the guarded tools with no preflight override; release on Jason's word.

---

## 11. Out of scope / M24

- **M24 — a dates-only "Coming up" widget**, after 1.13.0 (with the pin) has shipped: Jason registers
  `group.com.soundpost.Soundpost` (an Apple account change) and decides seals only or also echoes, and
  Home Screen only or also the Lock Screen (a date can reveal an anniversary). The app writes a small
  versioned JSON of future dates (no ids, notes, places or counts) into the group — never the store —
  from `NotificationCoordinator.sync`, and reloads the widget's timeline; the extension reads it with
  `FileManager.containerURL` + `Data(contentsOf:)`. The widget build must pass an entitlement-present
  upgrade test on a device. `verify-archive.sh` compares each binary's signed entitlements with an
  allowlist (learned from a real dry archive). Six `WidgetExtensionTests` guards change deliberately.
- The stale-cancel family with a guarded server cancel (item 6: migration 0004 with defaulted
  `p_expected_wall_clock` / `p_expected_time_zone`, dropping the two-argument signature so PostgREST sees
  one function; `sync-delivery` passes them, with its first tests; the app sends them) and **B1** — after
  S0 and a multi-device witness.
- A content-free daily count of pushes sent (`notification_daily_counts`) — after S0.
- `sealedAt` (needs a Console deploy and Jason's go); `CLGeocoder` → `MKReverseGeocodingRequest` and
  VideoExporter's AVAssetWriter/Reader migration — both when the deployment target rises (no warning at
  17.0 today); the Swift 6 strict-concurrency re-measure (now 91 files / 16.5k LOC plus the widget, vs
  M12's 55 / 6.4k) and flip.
- **Closed (with reopen triggers):** the orphan audio sweep (rule 6; reopens only if Sentry shows a
  nonzero orphan notice **and** Jason relaxes rule 6 with a recording-lease design) and the rejection
  identifier migration (reopens on a `VocabularyPinTests` failure from a rename or a new
  `SNClassifierIdentifier`).
- An app preview video with real sound (Jason records it); the landing page's Smart App Banner and `og:`
  tags; Sentry app-hang V2.
- Dropped under the rules: Live Activities, a "start recording" intent, new notification kinds, product
  page optimization at this traffic, Siri suggestion donation (it would put suggestions on the Lock Screen
  — a prompt).

---

## 12. Review record

### Round 1 — Gemini 3.8 Flash (high), via `agy --mode plan`, and four review lenses, 2026-11-11

Revision 1 was reviewed by Gemini (read-only tools, no shell) and by four independent lenses
(feasibility, tests and gates, promises / privacy / copy, sequencing and release safety). **Every finding
was then re-checked against the code by a separate skeptic** before the plan changed. Gemini: 11
findings, verdict CHANGES REQUESTED — after checking, 1 right, 7 partly, 2 wrong, 1 right but trivial, no
blocker. Lenses: 6 + 12 + 11 + 13 findings, verdict CHANGES REQUESTED from each; after checking, all
right or partly right, several downgraded. Merged where they overlap (Gm = Gemini; L-P, L-G, L-F, L-S =
the lenses):

| ID | Sev. (checked) | Finding | Check | Change |
|---|---|---|---|---|
| L-F1, L-S2 | major | Pruning `.claude/` from the copy scan does not help: the preflight's clean check and the non-overridable HEAD/clean guard still count `.claude/x 2.lock` — the case that forced 1.12.0's override | right (`release-preflight.sh:88-91`, `build-upload-asc.sh:120-121`, `.git/info/exclude:8`) | §4B.3 one dirty rule excluding `.claude/`, used by both |
| L-S1 | major | `ALLOW=sentry` + unset token uploads with no dSYMs: `upload-dsyms.sh` exits 0 without a token; `ALLOW=dirty` is dead weight | right (`upload-dsyms.sh:23-32`) | §4B.3 names only `copies`/`keychain`/`build-number`; `--required` in upload mode |
| L-G1, L-F10 | major | S1's fixtures would fail against the old scripts for unrelated reasons (missing key, keychain, no `GATE_PROJECT_DIR`), proving nothing | right (`build-upload-asc.sh:24,34,54`; preflight probe) | §4B.0 extracted `release_policy.sh`, `GATE_PROJECT_DIR`, stubbed tree, messages asserted |
| L-F2, L-S8, L-G11, Gm4 | major→minor | "Refuse if the path exists" dead-ends every post-archive failure; the dated path does not enforce one-build-once; defaults read `VERSION` before it is set; "dry run = paths set" contradicts the refusal fixture | right / partly | §4B.2 refuse only an uploaded build; next attempt name; defaults after `VERSION`; dry run = archive mode |
| L-G2 | major | The 27.2 job's gate list omitted the Python policy tests and seed coverage; after D23 they would run nowhere; `MIN_TESTS` is job-level | right (`ci.yml`) | §4C.2 every step; workflow-level `MIN_TESTS`; `MIN_PY_TESTS` |
| L-G3 | major | `CapsuleActions.seal` breaks two pins the plan did not name and adds none proving production calls it | right (`WriteFailureViewGuardTests:18-24`, `CaptureSealTests:171`) | §4F.1 pins rewritten, call-site census |
| L-G4 | major | The far-seal control cannot fail; test 3 passes an implementation that resolves on every failure | right (traced) | §4F.1 tests (2)–(5) with working controls |
| L-G5, Gm7 | major | `SiriTipView(intent:)` has `isVisible: nil` — dismissal is not held; "only in SettingsView" passes when deleted; censuses are in `CaptureDoorTests` | right (`_AppIntents_SwiftUI.swiftinterface:47`) | §4E.1 `@AppStorage` binding, exactly-one census, dismiss witness |
| L-F3, L-S9, L-G12, Gm11 | major | Switching the display type leaves the inherited 6.5-inch set on 1.13.0; the type is hard-coded in three places | right (`asc.py:441,520-521`) | §4B.7 one constant; stale set removed; `check-submittable` reports types |
| (Gm11 check) | major | The screenshot API path may be deprecated (App Asset Library), and `DELETE /v1/appScreenshots` may hit live images; `_69` is likely not a type | partly (RoastMate note, unverified with Apple) | §4B.7 settle read-only first; no delete until then; H5 |
| L-S3, L-P1 | major→minor | The plan added an unseen Lock Screen claim in-app and kept the listing's by default; S7 did not wait for a witness | right (1.13.0 would be the 2nd release with it, not the 3rd) | §0, §4E.1, §4H Lock Screen only if seen, else removed and pushed |
| L-P2 | major→minor | Bold defaults read as consent for the analytics POST; "deployed on Jason's word" vs §1.9 "done by Jason"; only EN promo drafted | partly | §8 header line; D5 "on your word"; §4F.2 Jason deploys; three promo texts in §4H |
| L-S12 | minor | The analytics request sat in S7, defeating the baseline | right | §4B.8 in S1 |
| L-S6 | minor | Xcode can auto-update before S7; the pin had no way out; dropping the 27 job left §0 unmeetable | right | §4C.3 preflight compares first; H6; §2 drop rule |
| L-S4 | major→minor | W7 could land after the one S6 pass | partly | §5.3 ordering and a second-pass rule |
| L-S7 | minor | "Or withdrawn" cannot run: a withdrawn record stays editable; no rename command | right | §3.1, H1, §4H "released" only |
| L-S10 | minor | Option A facts: force-quit missing; tap opens the sealed detail, not the reveal; the row survives app opens; B's window is 24 h | right | §4A steps 4–5, D15 |
| L-S11, L-P6 | minor | `user_key` is the bearer credential and the repo is public; "proved" overstated for iOS 17 | partly | §1.9, §1.13, §4A column rule, §6 |
| L-S5, Gm1, L-F6 | minor | The drain resolves an unstamped far seal's entry before the server holds it; `normalizeSealHours` clears the stamp before returning | right (`CapsuleStore.swift:375`; drain `:268-296`) | §4F.1 resolve only when stamped; snapshot stamps before the call |
| L-F5 | minor | `retryLabel` cannot see the reason: `apns.ts` drops it on retry; both branches write a fixed label | right (`apns.ts:143-159`, `index.ts:180-197, :209-229`) | §4F.2 and §3.10 |
| L-F7, Gm2 | minor | Which app info: there are two while a version is in flight | right (Gm2's "uses APP_ID" premise **wrong**: the plan never said so; the endpoint is the one M21 used) | §4B.5 select the editable app info |
| L-F8, L-G7, L-S13, Gm-(check) | minor | The AST order check missed `cmd_submit`'s indirect write via `cmd_cancel` and the reuse branch; `create-version`'s payload unpinned | right (`asc.py:351,380`) | §4B.1 |
| Gm3 | minor | `create-version` leaves an existing non-MANUAL version alone | partly (an unconditional PATCH would write to a version in review) | §4B.1 PATCH only in `PREPARE_FOR_SUBMISSION` |
| L-F9 | minor | A project-list probe needs a scope the dSYM token may lack | partly (unverified) | §4B.6 probe what the upload uses; 401 fatal, 403 warn |
| L-F4 | major→minor | The doors shot had no staging hook and would show the iCloud row the script keeps off the store | right (`ContentView.swift:141-142`) | §4G `-screenshotScreen doors`, dropped if the row is in frame |
| L-G6 | minor | The toolchain check breaks `ArchiveTests`' good fixture; a fixture reading the env file compares '' with '' | right | §4C.3 literals, negative fixtures, app/appex |
| L-G8 | minor | The picker rule had no fixture; dropping the 27 job leaves the pin with no CI behind it | partly | §4C.4 `pick_simulator.py`; §2 |
| L-G9 | minor | A Linux Deno job can be green without running Deno | right | §4C.5 counts and markers required |
| L-G10 | minor | "No `entry.`" and independent counts are evadable | right | §4E.3 exact-text pins |
| L-P3 | minor | No gate checks rule 1 for in-app strings | partly (the plan said "reviewed", not "gated") | §1.1, §4E.1 hand review recorded |
| L-P4 | minor | The section lacked the door qualifier every other surface carries | partly (consistency, not a rule-1 defect) | §4E.1 reuse the existing key |
| L-P5 | minor | §0 promised three languages on 18.5; §4G scheduled one | right | §4G |
| Gm5 | — | A missing screenshot dir fails `find` under `set -u` | **wrong** (stderr discarded, status unread; the real risk is a missing root passing) | §4B.3 required roots fail closed |
| Gm6 | minor | The toolchain file must not be asserted in the 26.6 job | partly (ambiguous wording) | §4C.3 |
| Gm8 | minor | `check-submittable` must check the app first | partly | §4B.5 |
| Gm9 | minor | `URL + String` does not compile | right | §4E.2 `appending(queryItems:)` |
| Gm10 | — | The S0 `UPDATE` must clear `locked_at` | **wrong** (only a claim of an already-due row sets it; every exit clears it) | §4A step 3 reads `locked_at is null` |
| L-F11 | minor | Stale citations (preflight `:128`, Sentry check `:110-119`, `red` `:57`/`:61`, consumers, `Soundpost-Shots` is a listed temporary device) | right / partly | §3.2, §3.7, §4B.2 |

Verdict: CHANGES REQUESTED → revised (revision 2).

### Round 2 — Gemini 3.8 Flash (high) on revision 2, and a consistency review, 2026-11-11

Gemini re-read the plan and the files (read-only tools, no shell): 7 findings, verdict CHANGES REQUESTED;
each was checked against the files and all hold (R2-2 partly — whether `iPhone 17` exists on the
`macos-26` image is unknown from here). A separate consistency review read the whole of revision 2
against itself and the code (about 70 citations spot-checked, 5 off): 4 major and 22 minor problems, no
blocker. Applied:

| ID | Sev. | Finding | Check | Change |
|---|---|---|---|---|
| C-1 | major | The "offline" store-gate rule would fail CI on `description.txt:19`'s "offline-first", and a must-not-appear rule needs its own code and fixture | right (`check-store-metadata.py:80-85, :182`; `test_gates.py:390-392`) | §4H check limited to `promotional_text.txt`, same commit, M8-text fixture |
| C-2 | major | Dropping the Linux job then retiring 26.6 would leave the delivery-server tests running nowhere | right | §2 drop rule; §4C.6 D23 waits for S2.5's condition |
| C-3 | major | S6 built "the S5 commit", which may predate W7 | right | §4G HEAD once S5 and W7 have landed |
| C-4 | major | `screenshots.sh` `rm -rf`s `build/screenshots/<locale>` — the set the store shows, and Jason's to delete | right (`screenshots.sh:32, :132`) | §4G output to `~/Library/Caches/Soundpost-build/screenshots-69/` |
| R2-3, C-16 | major | The Deno control "apns.ts drops the reason" cannot fail a test that feeds `retryLabel` a hand-made outcome | right (`state_test.ts:4-5`; `apns_test.ts` tests only the host) | §4F.2 drive `apns.ts` with a stubbed `fetch` |
| R2-6 | minor | Moving the save into the normalize helper would leave `refreshDueSeals`' flips unsaved | right (`ContentView.swift:607-610`) | §4F.1 `normalizeAndRefresh`, same order, one save |
| R2-1 | major→minor | Every `ArchiveTests` case would fail on a missing env file | right (`test_gates.py:447-450`) | §4C.3 `setUp()` writes it |
| R2-2 | major→minor | The picker's arguments differ per job | partly | §4C.4 per-job arguments from S2.1 |
| R2-4, C-14 | minor | The guard placed before `if not v:` receives `None` | right (`asc.py:304-306, :364-366`) | §4B.1 after the exit |
| R2-5 | minor | `archive_plan` needs an archives root to be testable | right | §4B.0 signature |
| R2-7, C-11 | minor | Copy-scan fixtures need stub roots, and `ALLOW=keychain,build-number` implies upload mode where the clean and Sentry checks still decide | right | §4B.3 archive mode, stub dirs |
| C-10 | minor | `':(exclude).claude'` also hides tracked changes there | right | §4B.3 filter `??` lines; tracked-file fixture |
| C-12 | minor | Nothing implemented "refused before archiving" with the preflight stubbed | right (`build-upload-asc.sh:133-151`) | §4B.3 token and probe before `xcodebuild archive` |
| C-13 | minor | "Records an upload" also matched a failed upload; the remnant 1.12.0 copy would refuse a dry run at (24) | right (`uploadEvent.state`) | §4B.2 successful upload only; both modes; scratch root for dry runs |
| C-15 | minor | App-info states observed during review are not those at submit; fixture order matters | right | §4B.5 pin the live state; live-first fixture |
| C-17 | minor | Control (2) may pass in a host with no App Group | partly | §4D.2 record that (c) catches it |
| C-6 | minor | S2.1's no-image branch contradicted §2 and orphaned the toolchain file | right | §4C.1 |
| C-7 | minor | "Shut down after" would stop the shared `iPhone 17 Pro` that S1–S5's local runs rely on under 30 GB | right | §1.12, H2 |
| C-8 | minor | H1's withdraw branch would carry the unseen Lock Screen line | right | H1 |
| C-9 | minor | The failed-warm-tap branch missed the in-app Control Center line and a failure after W7 | right | §5.3 |
| C-18 | minor | §2's table omitted H4–H6, D3, D23, §4B.4, §4B.7 | right | §2 |
| C-19 | minor | Due dates of other users' jobs were published | right | §0, §3.10, §4A dates removed |
| C-20 | minor | ZH 「锁定屏幕」 vs the catalog's 「锁屏」 | right (`Localizable.xcstrings:2005, :2972`) | §4E.1 |
| C-21 | minor | ライフログ suggests continuous logging; 記録 redundant | right (§1.1) | §4H keywords (and 生活记录 dropped likewise) |
| C-22 | minor | "Every shipped binary" built with 27B52 was overstated | right | §3.3 |
| C-23 | minor | D18's "keep a 6.5-inch set too" contradicted `check-submittable` | right | D18 |
| C-24 | minor | The deliberate red CI control must not land on master | right | §4C.2 throwaway-branch PR |
| C-5, C-25, C-26 | minor | "Before and after" in one pass; promo AST control; S3.3 signing settings; five citations and "M22 D14" | right | §4E.3, §4G, §4H, §4D.3, §3 |

Copy checked by the consistency review: the promotional texts are 152 / 69 / 49 characters, hit no
blocked term or §1.1 word, and pass the "offline" check; the keyword drafts total 81 / 74 of 100 before
the two removals; the Settings lines are clean against §1.1.

Verdict: revised (revision 3). No finding of either round remains open; the remaining unknowns are
named in the plan as things S1 / S2 read first (§4B.7 screenshot API, §4C.1 runner image, §4B.5 app-info
state).

### Round 3 — Gemini 3.8 Flash (high) on revision 3, 2026-11-11

Gemini checked every row of the round-2 table against the files it cites and found all 29 applied as
described. It raised two findings, both checked against the files and both right:

| ID | Sev. | Finding | Check | Change |
|---|---|---|---|---|
| R3-1 | major | S7 created `release_notes-1.13.0.txt` but never updated `release_notes.txt`: the store gate fails on the mismatch, and `asc.py notes` would push 1.12.0's notes | right (`check-store-metadata.py:152-156`, `asc.py:287-289`) | §4H, and the kickoff prompt |
| R3-2 | minor | The kickoff prompt's decision list skipped D1 | right (D1 is settled by §1.3) | §8 D1 "settled; not re-asked"; the prompt says so |

Verdict: CHANGES REQUESTED → both applied (revision 4). Nothing open.

---

## 13. Build record

*(one subsection per step: commits, tests and counts, controls, gate fixtures, simulator witnesses,
CI runs, deviations from this plan and why)*

### Day one (2026-11-12)

Re-verified before any change: master `44d3fdc`, tree clean, CI green on it; 1.12.0 (24)
`WAITING_FOR_REVIEW`, `releaseType MANUAL` (read back); 21 GB free; Xcode 27.2 (27B52) local;
`build/Soundpost.xcarchive` still has an empty `Products/Applications/`. Jason was sent S0 (both
options, the read columns), H1–H6 and D3, D5–D9, D11, D15–D23 with their defaults, in Chinese. No
answer yet: nothing outside the repo was written (no analytics POST, no production read).

### S1 — release safety

**What changed.**
- `scripts/lib/release_policy.sh` (new, sourced, bash 3.2): `default_archive_path`, `archive_plan`
  (refuses only an archive whose `Info.plist` records `destination = upload` with
  `uploadEvent.state = success`; otherwise the next free `… - attempt <n>.xcarchive`),
  `archive_records_upload`, `allow_validate` / `allow_has`, `legacy_override_refused`,
  `tree_is_dirty` (porcelain lines minus `?? .claude/…`, quoted or not; a failing git is dirty),
  `copy_scan` (roots from `project_model.py roots --kinds app,appex,test,other`, the `.xcodeproj`,
  `metadata/`, `scripts/`, `backend/` — each required — plus the screenshot folder if present;
  0 / 1 found / 2 cannot scan), `should_push_tag`, `sentry_token_problem`, `sentry_probe` /
  `sentry_probe_verdict` (the org's `chunk-upload/` options: 2xx pass, 401 fatal, else warn).
- `release-preflight.sh`: honours `GATE_PROJECT_DIR`; the retired `RELEASE_PREFLIGHT_OVERRIDE` is
  refused with a message naming `RELEASE_PREFLIGHT_ALLOW`; `ALLOW` takes only `copies`,
  `keychain`, `build-number` (`dirty`, `sentry`, anything else refused by name); one dirty rule;
  the narrowed copy scan, failing closed; `ASC_PYTHON` defaults to
  `~/Library/Caches/Soundpost-build/asc-venv/bin/python3` (`/tmp/asc-venv` only as a fallback),
  with the rebuild command printed.
- `build-upload-asc.sh`: versions read first, then `archive_plan` under `ARCHIVES_ROOT`
  (default `~/Library/Developer/Xcode/Archives`); an explicit `ARCHIVE_PATH` that exists is
  refused; nothing deletes an archive (`rm -rf` now touches only the export folder,
  `~/Library/Caches/Soundpost-build/export/<v>-<b>/`). Upload mode checks the token and runs the
  probe before `xcodebuild archive`, applies the dirty rule to the HEAD/clean guard (no setting
  skips it), calls `upload-dsyms.sh --required`, tags, and pushes the tag (a failed push warns and
  prints the command; exit 0). Archive mode never tags or pushes.
- `upload-dsyms.sh --required`: no `sentry-cli` or no token exits 1; without it, unchanged; the
  stale `--backfill` comment corrected.
- `verify-archive.sh`: comment only (no setting skips it).
- `asc_policy.py`: `require_manual_release`, `release_type_plan`; the screenshot constant
  (`APP_IPHONE_67`, 1320×2868, screens, folder `~/Library/Caches/Soundpost-build/screenshots-69`,
  overridable by `SOUNDPOST_SCREENSHOT_DIR` for fixtures), `screenshot_files`,
  `screenshot_target_set_plan`, `stale_placements`; `editable_app_info`, `age_rating_gaps`,
  `submittable_problems`; `analytics_request_plan`. `screenshot_swap` removed (nothing deletes
  screenshots any more), with its five tests.
- `asc.py`: `attach` and `submit` call `require_manual_release(v)` as the statement right after the
  `if not v:` exit; `submit` then runs `submittable_problems` and refuses on any; `create-version`
  POSTs `releaseType: 'MANUAL'`, and for an existing version PATCHes MANUAL only in
  `PREPARE_FOR_SUBMISSION` (read back), otherwise prints; `status` shows `releaseType`; new
  `check-submittable` (GET only, app checked first), `screenshots-prune [--apply]` (placement
  deletes on the editable version, dry run by default), `analytics-request` (one POST, refuses a
  second — **not sent**: D5 is Jason's), `analytics` (GET only, to
  `~/Library/Caches/Soundpost-build/analytics/`). `cmd_screenshots` uploads only the names the
  policy accepts, from the policy's folder, into an empty `APP_IPHONE_67` set, and never sends a
  DELETE.
- `screenshots.sh`: reads the screens, display type, size and folder from `asc_policy`; writes to
  the Caches folder (`.no-sweep`), refuses a folder in `~/Documents` or the repo; `red` defined
  before use. The device stays `Soundpost-Shots` until S6, so until then it refuses on size.

**§4B.7, settled read-only** (Apple's documentation read on 2026-11-12, plus reads of this app):
- (a) `appScreenshotSets` / `appScreenshots` are **deprecated** (API 4.5) in favour of App Asset
  Library images and placements
  ([4.5.1 release notes](https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-4-5-1-release-notes),
  [App Screenshot Sets](https://developer.apple.com/documentation/appstoreconnectapi/app-screenshot-sets));
  no sunset date is published, and they still answer (read on 1.12.0 today).
- (b) A new version's screenshots are **its own placements over the same library images**: on
  1.12.0 the inherited set is four `IPHONE_FACE_ID_LARGE_PROFILE` placements created with the
  version; its `appScreenshot` ids differ from 1.11.0's while the image assets (template URL,
  asset token, checksum) are identical. A placement delete
  ([Placing assets](https://developer.apple.com/documentation/appstoreconnectapi/placing-assets-on-your-app-store-surfaces))
  removes the asset from that surface and leaves the image in the library.
- (c) **Not documented.** [DELETE appScreenshots](https://developer.apple.com/documentation/appstoreconnectapi/delete-v1-appscreenshots-_id_)
  says only to use the image delete instead, and an image backs the live version's placements;
  [image deletes with placements fail](https://developer.apple.com/documentation/appstoreconnectapi/uploading-and-managing-image-assets)
  (`STATE_ERROR.ASSET_HAS_PLACEMENTS`). So asc.py never sends it (pinned by
  `test_nothing_in_asc_py_deletes_a_screenshot_or_an_image`); the stale set leaves 1.13.0 by
  `screenshots-prune` (placement deletes, only once the new group holds exactly the four new
  images) or by Jason in the web UI (H5).
- (d) [ScreenshotDisplayType](https://developer.apple.com/documentation/appstoreconnectapi/screenshotdisplaytype)
  has no `APP_IPHONE_69`; `APP_IPHONE_67` is the largest iPhone value. The
  [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
  accept 1320×2868 for "iPhone with Dynamic Island (large display)", and require 6.5-inch only when
  that is absent. No Apple page maps the class to the enum value; `APP_IPHONE_67` follows Jason's
  RoastMate tool (`asc_product_page.py:136-149`). The new placement group
  (`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE`) is by the same analogy; `stale_placements` removes nothing
  until S7 sees it holding the upload. **Open for S7:** the same page's "required device sizes"
  also mentions a medium-display iPhone screenshot; `check-submittable` and the submit will say.

**Other reads (S1).** App infos: live `state = READY_FOR_DISTRIBUTION` (pinned as
`LIVE_APP_INFO_STATE`), the in-flight one `WAITING_FOR_REVIEW`. Both age-rating declarations leave
exactly four attributes null — `developerAgeRatingInfoUrl`, `gracRatingClassificationNumber`,
`kidsAgeBand` (optional) and `socialMediaAgeRestricted` (follow-up to `socialMedia = false`) — the
allowlist. `check-submittable` on 1.12.0 reports exactly the six screenshot items the new constant
predicts (no `APP_IPHONE_67`, a stale `APP_IPHONE_65` set, per locale) and nothing else. Every
Soundpost archive in Xcode's Archives (1.2.0, 1.10.0, 1.11.0, and the 1.12.0 remnant) records
`uploadEvent.state = success`, so a dry run at build 24 is refused unless it passes a scratch
`ARCHIVES_ROOT`. Sentry: the token is a user auth token (`sntryu_` prefix) whose scopes include
`project:releases`, `project:write` and `org:read`; the probe answers 200 with it and 401 with a
bogus one.

**Proof.** Python suite 78 → 153 tests (`test_asc_policy.py` 48 → 77; `test_gates.py` 30 → 76:
`ReleasePolicyTests` 20, `PreflightTests` 9, `BuildUploadTests` 14, `UploadDsymsTests` 4).
The release-path fixtures run against the scripts at `44d3fdc` (each old script copied into the
fixture tree so its own location names the tree): **20 of 27 fail**, for the reason under test:
the archive path (`build/`), the overwrite of an existing `ARCHIVE_PATH`, no refusal of an uploaded
build, no token check or probe before the archive, no `--required`, no tag push, the old override
accepted, a missing scan root passing, and `.claude/scheduled_tasks 2.lock` reported both as an
iCloud copy and as a dirty tree (old output read, not only the exit code); two pass-cases fail
because the old preflight has no named allowance at all. The seven that pass against the old
scripts are regression guards (a source-root copy, another untracked file, a change during the
archive, a moved HEAD, no token in the preflight, archive mode not tagging, a dry archive warning).

**Controls** (`scratchpad/mutate_s1.py`: `cp` snapshot → mutate → run the named tests → restore
→ `cmp`; all 25 killed):

| Mutation | Killed by |
|---|---|
| `archive_plan` refuses on mere existence | `test_an_earlier_unuploaded_attempt_is_left_intact`, `test_a_failed_attempt_is_kept_and_the_next_name_used` |
| a failed upload counts as uploaded | `test_a_failed_upload_moves_on_to_the_next_name` |
| dirty rule without the `.claude` filter | `test_another_sessions_untracked_lock_is_not_dirt`, `test_upload_counts_untracked_claude_files_as_clean` |
| dirty rule as a pathspec exclude | `test_a_tracked_change_under_claude_is_dirt` |
| a missing scan root skipped | `test_a_missing_required_root_fails_closed`, `test_a_missing_scan_root_is_a_failure_not_a_pass` |
| scan the whole checkout, no prune | `test_copies_under_claude_are_ignored`, `test_other_sessions_files_do_not_block_a_release` |
| 403 fatal | `test_the_sentry_probe_verdicts`, `test_a_forbidden_probe_only_warns` |
| `ALLOW=dirty` accepted | `test_only_three_checks_can_be_named` |
| no token check before the archive | `test_an_upload_without_a_token_is_refused_before_archiving` |
| dSYMs without `--required` | `test_an_upload_requires_its_dsyms` |
| tag not pushed / archive mode tags | `…_pushes_its_tag_once` / `test_archive_mode_never_tags_or_pushes` |
| `--required` only warns | `test_required_without_a_token_fails`, `test_required_without_sentry_cli_fails` |
| `attach`: MANUAL guard moved into `else:` | `test_attach_and_submit_refuse_a_non_manual_version_before_any_write` |
| `submit`: MANUAL guard moved after `cmd_cancel` | same test |
| `create-version` without `releaseType` | `test_create_version_posts_manual` |
| `cmd_screenshots` sends `DELETE /v1/appScreenshots` again | `test_screenshots_never_delete_…`, `test_nothing_in_asc_py_deletes_…` |
| `screenshots-prune` without its dry-run return | `test_prune_removes_placements_only_with_apply_and_by_the_policy` |
| `editable_app_info` picks the first | `test_the_editable_app_info_is_read_even_when_the_live_one_is_listed_first` |
| a follow-up always skipped | `test_a_follow_up_counts_once_its_question_says_it_applies` |
| stale display types not reported | `test_a_stale_display_type_is_reported` |
| a missing `releaseType` passes | `test_a_missing_release_type_is_refused` |
| extra screenshot names accepted | `test_an_icloud_copy_is_refused_by_name` |
| analytics request repeated | `test_an_existing_ongoing_request_is_not_repeated` |
| stale placements removed before the upload is complete | `test_nothing_goes_while_the_new_group_is_incomplete` |

**On the real repo, no override:** `release-preflight.sh archive` passes (no copies, codesign
probe OK). `release-preflight.sh upload` refuses exactly two things: the uncommitted S1 changes and
build 24 (already on App Store Connect) — the build-number check ran through the new Caches venv
(Homebrew Python 3.14, `.no-sweep`).

**Standing bars.** Local `xcodebuild clean test` in place (Xcode 27.2, shared `iPhone 17 Pro`,
iOS 27.0, app uninstalled first): **752 tests in 98 suites**, `check-warnings.sh` clean,
localization 100%. No Swift changed; `MIN_TESTS` stays 752; the Python count (153) becomes
`MIN_PY_TESTS` in S2. **CI** on `6fa9411` ([run 43063372664](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43063372664)):
green — `Ran 153 tests`, `Executed 752 tests (floor 752)`, no warnings (Xcode 26.6, 8 minutes).

**Deviations.** (1) `RELEASE_PREFLIGHT_ALLOW` runs a named check and reports it as allowed rather
than skipping it, so the log still says what was gone past. (2) The copy scan also covers the test
target's root and a sibling `* N.xcodeproj`; a project the reader cannot read fails closed through
the reader. (3) §4B.7(c) is unsettled by Apple, so instead of "refuse to delete until settled" asc.py
deletes no screenshot at all, and `screenshots-prune` (placement deletes) is added for S7; until S7
reads the new group on 1.13.0 it removes nothing. (4) `screenshots.sh` already reads the constant
and writes outside iCloud in S1 (asc.py reads the same folder); its device and status-bar work stays
in S6. (5) No real dry archive in S1: every decision is exercised through the stubbed end-to-end
fixtures, and the first real run is S7's (the preflight there runs with no override).

### S2 — CI on the shipping toolchain

**S2.1, read first** (GitHub's `actions/runner-images`, 2026-11-12, through `gh api`):
[`images/macos/xcode-27-arm64-Readme.md`](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
— label `xcode-27` (also `xcode-27-xlarge`), arm64, macOS 27.0.1, image 20261104.0337.1, **still a
public preview** ([issue 14404](https://github.com/actions/runner-images/issues/14404), open; the
grounding's "GA since 2026-10-15" did not hold). Xcode 27.2 (27B52) at
`/Applications/Xcode_27.2.app`, **27.1 the default**, 27.0 beside them. iOS runtimes: 27.0 and one
27.2 runtime offer iPhone 17 / 17e / 18 Pro / 18 Pro Max / Air and iPads; 27.1 and a second 27.2
runtime offer only `iPhone Duo` — the old picker would have chosen it. `macos-26` (image
20261102.0473.1): Xcode 26.6 (17F113) default; iOS 26.2 / 26.4 / 26.5 offer iPhone 17.
Ubuntu: `ubuntu-24.04` ships PostgreSQL 16 (service off); `ubuntu-latest` was not used because the
26.04 image (PostgreSQL 18) exists beside it and the label can move.

**What changed.**
- `.github/workflows/ci.yml`: the macOS job is one definition with two matrix entries — Xcode 26.6
  on `macos-26`, Xcode 27.2 on `xcode-27` (`DEVELOPER_DIR=/Applications/Xcode_27.2.app/…`,
  `EXPECTED_XCODE "Xcode 27.2"` asserted as before) — `fail-fast: false`, 45-minute timeout. Only two
  steps are gated on the entry: the release-pin assertion (27.2) and the macOS delivery-server step
  (26.6, until the `server` job's logs have shown both counts on three pushes). `MIN_TESTS` (752) and
  the new `MIN_PY_TESTS` (168) are workflow-level; the Python step parses `Ran N` against it. The
  simulator is picked by name at the job's start and booted there; `simctl bootstatus -b` runs
  before `xcodebuild test`. Artifacts are named per image.
- `server` job on `ubuntu-24.04`: `denoland/setup-deno@v2` (v2.x; a failed install fails the job),
  `deno check` of the four import-free files (a warning, as on macOS), `deno cache` (an error),
  `deno test --no-check` with its `N passed` checked against `MIN_DENO_TESTS` 18 (today's count,
  local Deno 2.7.5), and `run-local.sh` against the image's PostgreSQL with its `ALL PASS`
  required. `run-local.sh` needed no change.
- `scripts/ci/pick_simulator.py` (new): the named device on the newest iOS runtime ≥ the minimum
  that offers it; non-zero with what exists otherwise. Arguments per entry: `"iPhone 17" 26` and
  `"iPhone 17" 27`.
- `scripts/release-toolchain.env` (new): `EXPECTED_RELEASE_XCODE_BUILD=27B52`, `MIN_SDK=iphoneos26`.
  Read by the 27.2 entry (its build must equal it), by `release-preflight.sh` before archiving
  (`toolchain_pin` / `toolchain_matches` in `release_policy.sh`: a mismatch refuses at once with the
  two ways out; no `ALLOW` name reaches it), and by `verify-archive.sh` (fatal): the app's and each
  appex's `DTXcodeBuild` must equal it and `DTSDKName` be at least `MIN_SDK`, both printed per
  bundle; the value must match `^[0-9]{2}[A-Z][0-9]+[a-z]?$`.

**Proof.** Python suite 153 → 168: `ArchiveTests` (`setUp` writes the pin; the good archive
writes `DTXcodeBuild 27B52` / `DTSDKName iphoneos27.2` as literals) +4 — printed per binary, a
missing or empty pin, a malformed pin, and five faults (the app by another Xcode, the app right and
the appex not, no `DTXcodeBuild`, no `DTSDKName`, an SDK below the minimum); `PreflightTests` +3
(another Xcode refused with both ways out even with every `ALLOW` name; a missing pin; the pinned
build passes); `SimulatorPickerTests` 5; `CiParityTests` 3. Against S1's scripts (`6fa9411`) all
seven toolchain fixtures fail (the old `verify-archive.sh` passes a wrong-toolchain archive; the old
preflight has no pin check).

| Mutation (`scratchpad/mutate_s2.py`) | Killed by |
|---|---|
| the old "first iPhone on the newest runtime" rule | `test_the_named_device_on_the_newest_runtime_that_offers_it` |
| the minimum major ignored | `test_a_runtime_below_the_minimum_does_not_count` |
| `verify-archive.sh` checks the app only | `test_toolchain_faults_are_each_refused`, `test_the_toolchain_is_printed_for_every_binary` |
| a missing pin passes | `test_a_missing_or_empty_pin_is_fatal` |
| the SDK minimum not compared | `test_toolchain_faults_are_each_refused` |
| a malformed build accepted | `test_a_malformed_pin_is_fatal` |
| the preflight's pin check nameable (`ALLOW=copies`) | `test_another_xcode_is_refused_with_the_two_ways_out` |
| no pin check in the preflight | the same, and `test_a_missing_pin_is_refused` |
| a third step gated on the matrix | `test_only_two_steps_differ_between_the_toolchains` |
| a job-level `MIN_TESTS` again | `test_the_floors_are_workflow_level` |

**Standing bars.** No file the app build reads changed since S1's local clean run
(`git diff 6fa9411 -- Soundpost SoundpostTests SoundpostWidget Soundpost.xcodeproj` is empty), so
that run (752 tests, 0 warnings) stands for this commit; CI's two toolchains are this step's new
evidence (below).

**CI.** `975ab77` ([run 43064844629](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43064844629)):
the Xcode 26.6 entry green — the picker chose `iPhone 17` on iOS 26.5, `Ran 168 tests`, `Executed
752 tests (floor 752)`, no warnings; the `server` job green on its first run — `Deno: 18 passed
(floor 18)`, `ALL PASS` from the SQL test against PostgreSQL 16 (the SQL test's first run on CI
ever). **The Xcode 27.2 entry failed before any gate:** its picker chose `iPhone 17` on iOS 27.2
(not the `iPhone Duo` runtimes), then `hashFiles()` on `Package.resolved` ran past GitHub's
120-second template limit on the preview image. `6d1da60` computes the cache key with `shasum -a
256` in the shell instead (the key changed once for both entries).

`6d1da60` ([run 43066658284](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43066658284)):
**all three jobs green** — the first green Xcode 27.2 run: `pinned 27B52, this runner 27B52`, `Ran
168 tests`, `Executed 752 tests (floor 752)`, no warnings, 20 minutes (cold package resolve); 26.6
the same counts; `server` 18 Deno tests and `ALL PASS`.

**The pre-boot, measured, then moved.** Booting the simulator at the job's start (as §4C.4 says)
starved the runner's disk: on `975ab77` / `6d1da60` a one-line step took 37–53 s (0 s on S1's run),
the cache restore 68–130 s (13 s), and the 26.6 job 9m45s against 8m00s — the boot saved about two
minutes in build-and-test and cost more before it; it is also what pushed `hashFiles()` past its
limit. The device is still chosen by name at the start; the boot now starts just before the
debug-only gate's compile, and `bootstatus -b` still precedes the tests (commit after `6d1da60`).

**Then dropped.** Booting during the debug-only compile was worse still: on `b27e081` that
compile took 6m42 (1m26 before) and the 26.6 job 14m33. Three measurements, one direction — every
early boot slowed what it overlapped more than it saved — so `101a41e` keeps no early boot at all:
the device is picked by name at the start and `simctl bootstatus -b` boots it and waits right
before `xcodebuild test`. (Deviation from §4C.4's "boot in the background at the start".)

**The control** ([JasonYeYuhe/Soundpost#2](https://github.com/JasonYeYuhe/Soundpost/pull/2),
throwaway branch `m23-s2-control-warning`, never on master): dropping `ContentView.swift`'s `import
StoreKit` turned the Xcode 27.2 job red at the warning gate (`ContentView.swift:9:47: warning:
cannot use struct 'RequestReviewAction'…`) while the 26.6 job stayed green (run 43068292942). The PR
was closed unmerged and the branch deleted.

**Green 27.2 pushes toward D23:** `6d1da60` (1), `b27e081` (2, S3: 755 tests, both toolchains).

**Deviation.** One matrix job instead of a separately written `test-xcode27` job: the plan's
requirement is "every step of the 26.6 job", and a matrix makes that true by construction
(`CiParityTests` pins the only two differences). D23's retirement is then deleting one matrix entry.

### S3 — the store stays where it is

**What changed.** `SoundpostModelContainer.onDiskConfiguration(cloudKit:)` =
`ModelConfiguration(schema: productionSchema, groupContainer: .none, cloudKitDatabase: cloudKit)`,
used by rung 1 (`.automatic`) and rung 2 (`.none`); rung 3 (in memory), every test and DEBUG
container untouched. Name, default URL flag and CloudKit settings unchanged. No entitlement.

**`StoreLocationTests`** (3 tests, two of them over both rungs): (a) each on-disk rung's `url`
equals `URL.applicationSupportDirectory.appending(path: "default.store")`, built independently;
(b) each equals the unpinned `ModelConfiguration(schema:cloudKitDatabase:)` 1.12.0 ships, in a
host with no App Group — the no-op proof; (c) a census over `Soundpost/`: exactly two
`onDiskConfiguration(` call sites, both in `SoundpostModelContainer.swift` (one `.automatic`, one
`.none`), and every `ModelConfiguration(…)` call (read to its matching parenthesis) is either
in memory or carries `groupContainer: .none`; the census `#require`s that it found the file.

| Control (`scratchpad/mutate_swift.py`, `-only-testing`, `-collect-test-diagnostics never`) | Caught by |
|---|---|
| `groupContainer: .none` dropped | (c) `everyOnDiskConfigurationIsPinnedAndBothRungsUseThePin` |
| `.identifier("group.com.soundpost.Soundpost")` | **a crash**: SwiftData traps with "Unable to find App Group Container in Entitlements" when `url` is read in a host without the group, so (a) and (b) never return; `xcodebuild` lists all three under `Failing tests:` and reports `TEST FAILED`. The plan expected a fallback to the default location; there is none. (c) would catch it in a host that did not trap. |
| the store renamed (`"library"`) | (a) and (b) |
| rung 2 built unpinned again | (c) |

**Standing bars.** Local `xcodebuild clean test` in place: **755 tests in 99 suites**, no
warnings. `MIN_TESTS` 752 → 755.
**CI** `b27e081` ([run 43070068413](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43070068413)):
green on Xcode 26.6 and 27.2 — `Executed 755 tests (floor 755)` on each, no warnings, `Ran 168
tests`; `server` green.

### S4 — doors people can find

**What changed.**
- `SettingsView`: a "Ways to start a capsule" section before About — `SiriTipView(intent:
  OpenCaptureIntent(), isVisible: $showsSiriTip)` inside `if showsSiriTip`, where
  `@AppStorage("settings.showsSiriTip") private var showsSiriTip = true`; `ShortcutsLink()`; "Add
  the “New capsule” widget to your Home Screen."; inside `if #available(iOS 18.0, *)`, "Add “New
  capsule” to Control Center."; and as the section's footer, under those lines, the existing
  "Opens Soundpost ready to record. Recording starts only when you tap." The intent is constructed
  for the tip, never performed; `OpenCaptureIntent.swift` is untouched (its SHA test passes).
  The widget line does **not** name the Lock Screen: no Lock Screen face has been seen added and
  tapped (S6 / H4 decide).
- D17 (default yes, assumed for building): About gains `ShareLink("Share Soundpost", item:
  appStoreURL)` and `Link("Rate Soundpost", …?action=write-review)`, one `appStoreURL`
  (`https://apps.apple.com/app/id6778389097`). Passive rows; if Jason says no to D17 they come out.
- `LauncherWidget`: `.accessibilityElement(children: .ignore)` + `.accessibilityLabel("New
  capsule")` moved from the circular case onto `face` in `body`, before `.widgetURL` — every family
  now reads as one element (no new string).
- Five catalog keys (app catalog only; no widget string changed), translations drafted from the
  catalog's own terms.

**Copy, reviewed by hand against §1.1 and the store gate's off-sale terms (§1.3):**

| Key | ja | zh-Hans |
|---|---|---|
| Ways to start a capsule | カプセルを始める方法 | 新建胶囊的方式 |
| Add the “New capsule” widget to your Home Screen. | ホーム画面に「新しいカプセル」ウィジェットを追加できます。 | 可以把“新建胶囊”小组件添加到主屏幕。 |
| Add “New capsule” to Control Center. | コントロールセンターに「新しいカプセル」を追加できます。 | 可以把“新建胶囊”添加到控制中心。 |
| Share Soundpost | Soundpostを共有 | 分享 Soundpost |
| Rate Soundpost | Soundpostを評価 | 评价 Soundpost |

No "quickly / instantly / never miss", no すぐ / 瞬時 / 見逃さ, no 快速 / 立即 / 错过, no `!` / `！`;
no Pro, price, purchase or trial term. Each sentence is literally true where it is shown: the
widget line is read inside the app, so the app has launched once and iOS 18 lists its widgets; the
Control Center line exists only on iOS 18+. JA follows the description's 「新しいカプセルを始め
られます」; ZH uses the catalog's 新建胶囊, 主屏幕, 控制中心 and “” quotes as the catalog does.

**Guards** (`CaptureDoorTests`, over `shippingSources()`, beside the existing censuses):
`theDoorsAreNamedExactlyOnceInSettings` (exactly one `SiriTipView(` and one `ShortcutsLink(`, both
in `SettingsView.swift`), `aDismissedSiriTipStaysDismissed` (`isVisible: $<p>` where `<p>` is an
`@AppStorage` property, shown only `if <p>`, for `OpenCaptureIntent()`),
`theDoorsSectionIsBeforeAboutAndPerformsNothing` (order in `body`; no `.perform(` in shipping code;
`requestCapture` still one site), `shareAndRateAreOnePassiveRowEachInSettings`.
**Widget pins** (`WidgetExtensionTests`, comment-stripped exact text):
`theLauncherIsDisfavouredOnlyOnCarPlayAndMac`, `everyGlyphIsAccentableAndTheCircleHasItsBackground`,
`theFaceReadsNothingFromTheTimeline` (the `{ _ in LauncherView() }` closure; no stored property in
`LauncherView` but `@Environment(\.widgetFamily)`), `everyFaceReadsAsOneNewCapsule`.

| Control (`scratchpad/mutate_swift.py`) | Caught by |
|---|---|
| the tip and the link deleted | `theDoorsAreNamedExactlyOnceInSettings`, `aDismissedSiriTipStaysDismissed` |
| `doorsSection` left out of the form | `theDoorsSectionIsBeforeAboutAndPerformsNothing` |
| `ShortcutsLink()` moved into `ContentView` | `theDoorsAreNamedExactlyOnceInSettings` |
| `isVisible:` dropped | `aDismissedSiriTipStaysDismissed` |
| the flag as `@State` instead of `@AppStorage` | `aDismissedSiriTipStaysDismissed` |
| the Share row deleted | `shareAndRateAreOnePassiveRowEachInSettings` |
| `.carPlay` dropped | `theLauncherIsDisfavouredOnlyOnCarPlayAndMac` |
| a glyph's `.widgetAccentable()` moved onto its `Text` | `everyGlyphIsAccentableAndTheCircleHasItsBackground` |
| `{ e in LauncherView(stamp: e.date) }` | `theFaceReadsNothingFromTheTimeline` |
| the VoiceOver modifiers back on the circular face only | `everyFaceReadsAsOneNewCapsule` |
| one Japanese translation deleted | `check-localization.sh` (`[ja] "Ways to start a capsule" → missing`) |

**S4.4 RenderPreview spike — dropped** (second in §2's drop order): `xcrun mcp-server` exists in
Xcode 27.2, but serving this folder headlessly needs `mcp-server allow-folder` and agent approval,
both `sudo` (owner-only). Not attempted; no `#Preview` was added.

**Standing bars.** Local `xcodebuild clean test` in place: **763 tests in 99 suites**, no
warnings, localization 100% (363 strings). `MIN_TESTS` 755 → 763.
**CI** `2a56062` ([run 43073130348](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43073130348)):
green on 26.6 and 27.2 — `Executed 763 tests (floor 763)` each, localization passed, no warnings
(green 27.2 push 3).

### S5 — delivery, app-only

**What changed.**
- `CapsuleActions.seal(_:until:in:timeZone:now:commit:)`: a capsule that carries
  `serverJobSyncedAt` before the seal gets a durable pending cancel **before** the save; on a failed
  save (`commitSeal` puts every field back) only the entry this call added is resolved. The detail
  screen seals through it (after `requestAuthorization()`, as before).
- `CapsuleActions.normalizeAndRefresh(in:now:commit:)` replaces `refreshAndSync`'s three lines in
  the same order: the ids of stamped `.sealed` capsules are read **before**
  `normalizeSealHours` (which clears the stamp of what it moves), each of those it moves gets a
  pending cancel, then `refreshDueSeals`, then one save; a failed save resolves only the entries it
  added. `CapsuleStore.normalizeSealHours` / `refreshDueSeals` unchanged; `drainCaptureRequest()`
  still precedes the first `await`.
- `SealDeliveryService.drainPendingCancels`: a queued id whose capsule is still a far seal is
  resolved without a cancel **only once it is stamped**; unstamped it stays queued and sends
  nothing (the upsert that stamps it replaces the old job, same capsule id), and it is cancelled if
  the seal turns near or the capsule goes first. The stamped case — every existing test, including
  `aQueuedCancelForACapsuleStillInTheStoreCancelsNothing` — is unchanged.

**Tests** (`ResealOrphanTests`, 10; `withIsolatedDeliveryPreferences`, `isolatedStore()`,
`SpyDeliveryBackend`): (1) offline unseal → near re-seal → one cancel on the next reconcile;
(2) offline unseal → far re-seal with the backend throwing → still queued, no cancel; then the seal
inside the horizon → one cancel; plus the far re-seal's other ending (upserted and stamped, then
resolved with **no** cancel); (3) sealing a capsule with no job, near and far, queues and cancels
nothing; (4a) a failed seal removes its own entry and puts the capsule back; (4b) an entry queued
before a failed seal survives it; (5) a normalize that moves a stamped seal (23:00 Tokyo, 30 h out)
to 09:00 (16 h out) queues exactly one cancel, an unstamped one moved the same way none; a failed
normalize save resolves only its own entries; and two source pins — `commitSeal(` has exactly one
shipping call site, in `CapsuleActions.swift`; `refreshAndSync` normalizes through `CapsuleActions`
before the capture drain and the first `await`. Rewritten pins:
`WriteFailureViewGuardTests.aFailedSealOrUnsealTellsTheUserAndGoesNoFurther` (now
`CapsuleActions.seal(`, catch-body checks kept) and
`CaptureSealTests.theDetailScreenSealsAtTheInstantOfTheWrite` (the `CapsuleActions.seal(…, in:
store)` call after the prompt).

| Control | Caught by |
|---|---|
| (1) `seal` skips the enqueue | (1), (2) |
| (2) the drain resolves a far seal unconditionally (revision 1's rule) | (2) |
| (3) `seal` enqueues unconditionally | (3) — the near case records a cancel |
| (4b) a failed seal resolves on every failure | (4b) |
| (5) stamps read after `normalizeSealHours` | (5) |
| the detail seal writes `store.commitSeal(` directly | the census, `aFailedSealOrUnseal…`, `theDetailScreenSeals…` |
| `refreshAndSync` normalizes directly again | `theForegroundRefreshNormalizesThroughCapsuleActions` |

**S5.2 — a content-free failure reason (prepared; Jason deploys).** `apns.ts`'s retry outcome now
carries APNs' `reason`; `state.ts` gains a pure `retryLabel(outcomes)` (`dispatch_failed:http_403:
InvalidProviderToken`, `dispatch_failed:network`, distinct parts joined, reasons reduced to
`[A-Za-z0-9_]`, ≤ 200 characters); `index.ts` keeps the `DispatchOutcome[]`, passes the statuses to
`decideSettlement`, writes the label as `p_error` on both the retry and the dead-letter branch, and
logs `dispatch_rejected`. `dispatch_test.ts` (4 Deno tests) drives `dispatchToToken` itself with a
stubbed `fetch` (403 `InvalidProviderToken`, a thrown network error, a bare 500) and feeds its
outcome to `retryLabel`. Deno 18 → 22 tests; `deno check` of `index.ts` passes. Controls: `apns.ts`
drops the reason → the 403 test fails; `retryLabel` returns the fixed label → all four fail;
`network` not named → the network test fails. **Not deployed.** The deploy also carries M22's
undeployed `apns.ts:134` fix; Jason runs it only if S0 does not reach `sent`, or after S0 passes —
never during an S0 window: from `backend/`,
`supabase functions deploy send-due-notifications --project-ref gkjwsxotmwrgqsvfijzs --no-verify-jwt`
(before and after: the function's version in the dashboard, and `select status, attempts, last_error
from public.notification_jobs where status = 'pending'` — states only in §13).

**S5.3 (B2)** not built: S0 has not shown `sent`, D3 is not applied, D11 is unanswered — B2 moves to
M24 unchanged unless all three change before S6.

**Standing bars.** Local `xcodebuild clean test` in place: **773 tests in 100 suites**, no
warnings. `MIN_TESTS` 763 → 773; `MIN_DENO_TESTS` 18 → 22.
**CI** `d0a4a30` ([run 43076209192](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43076209192)):
green — `Executed 773 tests (floor 773)` on 26.6 and 27.2, no warnings; `Deno: 22 passed (floor
22)`, `ALL PASS` (green 27.2 push 4).

### S2.5 — the macOS delivery-server step removed

The `server` job's logs showed both counts (Deno passed count and `ALL PASS`) on `975ab77`,
`6d1da60`, `b27e081`, `2a56062` and `d0a4a30` — more than §4C.5's three — so the 26.6 entry's
Homebrew-Deno step (warning-only when Deno would not install, which happened on the control PR's
run) is gone, with its matrix flag; `CiParityTests` now allows exactly one per-entry step, the
release-pin assertion (control: gate a second step → `test_only_the_release_pin_differs…` fails).
**CI** `5be4809` ([run 43078204621](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43078204621)):
green — 773 tests on 26.6 and 27.2 (green 27.2 push 5), Deno 22.

### D23 and W7 — the 26.6 job retired; the control's intent runs only in the app

**D23 (default, assumed for building; Jason's to overturn by restoring the matrix entry).** The
Xcode 27.2 entry was green, with both test counts in its log, on five pushes — `6d1da60`, `b27e081`,
`2a56062`, `d0a4a30`, `5be4809` — and §4C.5's three-push condition held (S2.5), so the 26.6 entry
is gone. The shipped binary is 27.2-built (27B52, pinned), and the App Store minimum (Xcode 26 /
iOS 26 SDK) is met. The matrix stays, so a toolchain can come back as an entry that runs every
step. `CiParityTests` now pins the 27.2 entry and allows exactly one per-entry step.

**W7.** `NewCapsuleControlIntent` (shared `CaptureDoor.swift`, no `#if`) declares
`@available(iOS 27.0, *) static let allowedExecutionTargets: IntentExecutionTargets = .main`: iOS 27
may run an intent in any target that contains it, and in the extension `CaptureRequests.coordinator`
is nil, so a warm tap run there would open the gallery with no capture request. iOS 17–26 never
read it. `CaptureDoorTests.theControlsIntentRunsOnlyInTheApp` reads it on iOS 27 (control: `.default`
→ fails). **Beyond the plan:** the extension now names an iOS 27 type, and a strong binding would
stop it loading on iOS 17–18, so `verify-archive.sh`'s weak-symbol list gains
`IntentExecutionTargets|allowedExecutionTargets` with a fixture (an `IntentExecutionTargetsProbe`
bound strongly → refused; the old list passes it). Read from the built extension
(`SoundpostWidgetExtension.debug.dylib`, simulator): `IntentExecutionTargets.main`, its metadata
accessor and the `allowedExecutionTargets` requirement are all `weak external`.

**Standing bars.** Local `xcodebuild clean test` in place: **774 tests in 100 suites**, no
warnings. `MIN_TESTS` 773 → 774. Python 168 (a subtest added). S6 may now start once H2 allows.
**CI** `236a132` ([run 43081177535](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43081177535)):
green — the one macOS entry (Xcode 27.2, pinned 27B52 = runner 27B52) executed 774 tests (floor 774),
Python 168, no warnings; the `server` job passed with Deno 22 and `ALL PASS`.

### Jason's go-ahead (2026-11-12): D5, D7, D9 and D3

Jason, after the S1–W7 status message: 「你继续做吧 你检查没问题的话我全部同意」 — go on; if the
checks find no problem, he agrees to all of it. Read as his word for each action listed in the day-one
message with the recommendation given there, each done only after its own check. It does not cover
what §1 / the kickoff make his to run (production Supabase: S0's UPDATE, D3, S5.2's deploy) or what
needs an answer rather than consent (H3, H4, S0's phone steps); the 1.13.0 release is a separate word
(§4H). Disk at that moment: **9.0 GB free** (a macOS update is staged: `MSUPrepareUpdate` snapshot).

- **D5 — sent.** `analyticsReportRequests` listed first: none. Then `asc.py analytics-request`: one
  `ONGOING` request created (`879a93b3…`). Apple produces the first reports in a day or two;
  `asc.py analytics` reads them.
- **D7 — done, and seen to work.** Recent events carried `user.geo` with `city`, `region` and
  `country_code` (keys read, values not). Project `soundpost` gained one Advanced Data Scrubbing rule
  (`relayPiiConfig`): remove anything at `$user.geo.**` — all geo, not only the city, so the privacy
  label's "no location" holds without a decision about country-level data. Control: a test event
  (`environment` `m23-d7-check`, `ip_address` `{{auto}}`) sent before the rule was stored with city,
  region and country; the same event sent 90 s after it was stored with no `geo`, the event's `_meta`
  naming `project:0` as the remover. The test issue (those two events only) was then deleted (404 on
  re-read). Events stored before the rule keep their geo until Sentry's retention ages them out.
- **D9 — done as recommended.** Moved (`mv -n`, not trashed) to
  `~/Library/Developer/Xcode/Archives/<creation date>/Soundpost <version> (<build>).xcarchive`:
  `build/Soundpost 3…9.xcarchive` = 1.4.0 (8), 1.4.0 (9), 1.5.0 (10), 1.6.2 (15), 1.7.0 (16),
  1.8.0 (17), 1.9.0 (18) — none had an iCloud placeholder file. `.git/index 2` → Trash. Worktree
  `.claude/worktrees/dazzling-satoshi-fb69f2` (clean; its one commit `a637710` pushed, superseded by
  S1) removed with `git worktree remove`, its branch deleted locally and on `origin`. Remote
  `chore/build-roots-2026-10-15` had already been deleted on GitHub (`fetch --prune`). Kept:
  `release/1.6.1`, `release/1.6.2` (local and remote), `build/Soundpost.xcarchive`, the logs and
  `build/screenshots/`. **Found, not touched:** eleven more iCloud copies of the git index,
  `.git/index 3` … `.git/index 13` (2026-06-20 … 09-06; git reads only `.git/index`) — not in the
  list Jason saw, so asked.
- **D3 — ready for Jason.** `backend/supabase/tests/run-local.sh` re-run on this Mac (Homebrew
  PostgreSQL 17, throwaway cluster): `ALL PASS`. The command and the before/after reads went to
  Jason; nothing was written to production.

### D6 — promotional text

**What changed.** `metadata/*/promotional_text.txt` hold the three texts Jason approved (152 / 69 /
49 characters). `check-store-metadata.py` refuses, in promotional text only, EN "offline" except
"works offline", JA「オフライン」except「オフラインでも使え」, ZH「离线」except「离线也能用」 (each
allowed phrase is removed first, so it excuses only itself). `asc.py promo` writes
`asc_policy.promo_attributes(text)` — `{'promotionalText': text}`, nothing else — to every existing
localization of the live version and of the project's version if it is in flight
(`asc_policy.promo_targets`: `READY_FOR_SALE` plus the project's version in a pre-release state,
`PENDING_DEVELOPER_RELEASE` included; refuses with neither, or with two live versions), never creates
a localization, and reads every value back.

**Tests** (Python 168 → 178): `PromoTests` (6), `AscUsesThePolicyTests.test_promo_sends_only_
promotional_text_and_reads_it_back`, `PromoOfflineTests` (3, per-locale subtests).

| Control (`cp` snapshot, restored after each) | Caught by |
|---|---|
| the old `check-store-metadata.py` | `test_the_m8_text_fails_in_each_locale` (en-US, ja, zh-Hans: the M8 text passes the old gate), `test_works_offline_does_not_cover_a_second_bare_offline` |
| a second key in `promo_attributes` | `test_the_patch_body_is_promotional_text_only` |
| `{**promo_attributes(…), 'keywords': ''}` as the PATCH body | `test_promo_sends_only_promotional_text_and_reads_it_back` |
| a `post` for a locale the version lacks | same |
| the read-back replaced by the sent text | same |
| live version only (in-flight dropped) | `test_the_live_version_and_the_one_in_flight` |
| no refusal when there is nothing to write to | `test_nothing_to_write_to_refuses` |
| one allowed phrase excuses the whole text | `test_works_offline_does_not_cover_a_second_bare_offline` |

**Standing bars.** Local `xcodebuild clean test` in place: **774 tests in 100 suites**, no
warnings (no Swift changed). Python 178; `MIN_PY_TESTS` 168 → 178; `MIN_TESTS` stays 774.

**CI** `ca933f5` ([run 43192718243](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43192718243)):
green — 774 tests (floor 774), Python 178, no warnings, Deno 22, `ALL PASS`. **Found before the first push — `promo_targets` would have refused.**
Read on 2026-11-12, App Store Connect reports every version that ever shipped as `READY_FOR_SALE`
(`appVersionState` `READY_FOR_DISTRIBUTION`): 1.1.0 … 1.11.0, twelve of them. The first
`promo_targets` refused "more than one live version", so nothing was written. The live version is
now the newest released one by numeric version (`_version_key`; an unorderable version string
refuses); against the real list it resolves to 1.11.0 (`READY_FOR_SALE`) and 1.12.0
(`WAITING_FOR_REVIEW`). Tests: `test_the_live_version_is_the_newest_released_one` (replaces the
two-live-versions refusal), `test_an_unorderable_version_refuses`. Controls: the first released
version instead of the newest, and string order instead of numeric (`'1.9.0' > '1.11.0'`) → the
newest-released test fails. Python 178 → 179.

**CI** `2bc0860` ([run 43195017565](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43195017565)):
green — Python 179, 774 tests (floor 774), no warnings, Deno 22, `ALL PASS`.

**Pushed (Jason's word: the go-ahead above, for the three texts as approved).** Before: every
localization of 1.11.0 and 1.12.0 had empty promotional text. `asc.py promo` wrote 1.11.0
(`READY_FOR_SALE`, the live listing) and 1.12.0 (`WAITING_FOR_REVIEW`), each in en-US, ja and
zh-Hans; all six read back identical (152 / 69 / 49 characters). 1.12.0 stayed `WAITING_FOR_REVIEW`.

### S6 — the capture tooling (the witness pass itself waits)

**What changed.**
- `scripts/screenshots.sh` captures on the listed `iPhone 17 Pro Max` (iOS 27.0) by UDID —
  exactly one available device of that name on `com.apple.CoreSimulator.SimRuntime.iOS-27-0`, or
  it stops — under `/tmp/lock-iphone-17-pro-max`; it no longer creates `Soundpost-Shots`. It
  refuses while an `xcodebuild` run uses the device, boots it only if needed and shuts it down at
  exit only if this run booted it, sets the status bar (9:41, charged, 100 %, 3 Wi-Fi bars, 4
  cellular) and clears it at exit, writes its build log to
  `~/Library/Caches/Soundpost-build/shots-build.log` (it wrote `build/shots-build.log`), and
  refuses before 09:30 local time.
- `DemoData.seed(into:now:)`: each sample has a fixed daytime time on its own day (07:48 … 18:32;
  the sealed one 09:12), never after `now` (samples at most `now − 2 min`, the sealed one
  `now − 1 min`, so it stays newest); calendar days instead of `86_400`-second steps.
- `-screenshotScreen doors`: `ContentView` opens Settings; `SettingsView`'s form now sits in a
  `ScrollViewReader`, and in DEBUG only, for that launch argument, it scrolls the doors section to
  the top after 400 ms. `doors` is **not** in `SCREENSHOT_SCREENS` yet: it joins only after the
  capture shows, per locale, no iCloud row in frame.

**Tests.** `DemoDataClockTests` (2): seeded at 23:30, every capsule is between 07:00 and 19:59 and
not after `now`; seeded at 01:30, nothing is after `now` and the sealed capsule is newest.
`ScreenshotScriptTests` (6 pins on the script's code, not its header).

| Control | Caught by |
|---|---|
| `createdAt: day` (now minus days, as before) | both `DemoDataClockTests` |
| no clamp at `now` | `nothingIsRecordedAfterTheMomentOfSeeding` |
| sealed capsule `now − 3 min` | `nothingIsRecordedAfterTheMomentOfSeeding` |
| the old `screenshots.sh` (HEAD) | all six `ScreenshotScriptTests` |
| unconditional shutdown | `test_only_a_device_this_run_booted_is_shut_down` |
| first of several devices | `test_the_listed_device_by_exact_name_and_runtime_and_never_a_new_one` |
| build log back in `build/` | `test_nothing_is_written_into_build` |
| no status-bar clear | `test_the_status_bar_is_fixed_and_cleared` |
| lock never released | `test_the_device_lock_is_taken_and_released` |

**Not run yet — the witness pass and the capture.** At this point the Mac had **3–7 GB free** (a
16 GB staged macOS update in `/System/Volumes/Update`, and other sessions' builds), so neither the
`iPhone 17 Pro Max` nor `Soundpost-iOS18` was booted, whatever H2's exception allows. And the shared
`iPhone 17 Pro` — booted, the one device the rules let a run use under 30 GB — had a **frozen
display**: every `simctl io screenshot`, taps, HOME and the live panel returned the same 05:30
Home Screen frame (identical bytes) while the app ran (`launchctl` showed it) and tests passed on
it. Repairing that means restarting a device the rules say is never shut down, so it was left as
it was and reported. The doors staging is therefore unseen: it is DEBUG-only, `doors` is not in
`SCREENSHOT_SCREENS`, and nothing captures it until the pass runs.

**Standing bars.** Local `xcodebuild clean test` in place: **776 tests in 101 suites**, no
warnings, localization 100%. `MIN_TESTS` 774 → 776; Python 185, `MIN_PY_TESTS` 179 → 185.

**CI** `7082c11` ([run 43198052472](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43198052472)):
green — 776 tests (floor 776), Python 185, no warnings, Deno 22, `ALL PASS`; pinned 27B52 = runner.

### Jason's second go-ahead (2026-11-12, 22:30): D3 applied

Jason, after the status message that listed D3 and S5.2 as his to run and the frozen simulator as
his call: 「我清理好了 你继续吧 没问题的话直接全部执行」 — he has freed disk; go on, and if nothing is
wrong, carry all of it out directly. Read as his word for each item of that message, each after its
own check: D3, restarting the shared `iPhone 17 Pro`, trashing `.git/index 3…13`, releasing 1.12.0
once approved. Not covered, because it is not his to give by itself: S5.2's deploy waits on S0
(§4F.2 — after S0 passes, or if it fails, never before or during it), and S0 needs his phone. Disk at
that moment: 27 GB free (`~/.Trash` 19 GB, not emptied — that is his), 38 GB after the restart below.

- **D3 — applied.** Through the Supabase connector (`apply_migration`, named
  `m21_soundpost_delivery_hygiene`, as M10's were), the whole of `0003_m21_hygiene.sql` unchanged; the
  local test had passed earlier the same day (above). Before: `notification_jobs` held 3 rows —
  `pending` ×2, `pending / no_tokens` ×1; `cron.job` had only `m10_send_due_notifications`
  (`* * * * *`); no `m21_*` function. After: `m21_delivery_hygiene` `17 3 * * *`, active; the M10
  job unchanged; `m21_delivery_hygiene(timestamptz)` (security definer) and `m21_job_fire_instant`
  executable only by `postgres` and `service_role`; the 3 rows unchanged. Its first run (03:17 UTC)
  would expire 0 rows and delete 0 (the same predicates, counted).
- **`.git/index 3…13` — not moved.** `/usr/bin/trash` refused each with `NSCocoaErrorDomain 513`
  ("you don't have permission"), inside and outside the sandbox, while the same command trashed
  `.git/index 2` that morning and trashes a scratch file now; the console was locked at the time. Left
  as they are (git reads only `.git/index`).
- **The shared `iPhone 17 Pro` — restarted.** Its screenshots were still the 05:30 frame (the same
  bytes as the morning's). Nothing else was using it: the only `/tmp/lock-*` was Stride's
  `lock-stride-dd-…` from 11-10, whose pid had exited; no `xcodebuild`; the Stride app in it had been
  running since 11-08 with the device. Under `/tmp/lock-iphone-17-pro`: `simctl shutdown`, `boot`,
  `bootstatus -b`. Two screenshots 3 s apart then differed and showed the live clock. It stays booted.

### S6 — the witness pass (2026-11-12, 22:35–23:00)

Debug build of `7082c11` plus the fix below, through the shared package helper, no warnings. Devices
by UDID under their locks: the shared `iPhone 17 Pro` (iOS 27.0, `C53F6992…`, restarted above) and
`Soundpost-iOS18` (iOS 18.5, `DAF29479…`, booted for this pass under H2's exception, shut down after).
Text size and appearance restored on both (`large`, light); the 17 Pro's Home Screen icon style
put back to Default.

**Found and fixed — the Shortcuts link drew without the app's name in Japanese and Chinese.** With
`-AppleLanguages (ja)` the section's `ShortcutsLink` read 「のショートカット」, and in Chinese
「快捷指令」 — "Soundpost shortcuts" with the name gone. `InfoPlist.xcstrings` marked `CFBundleName`
"don't translate", so only `en.lproj/InfoPlist.strings` carried it; the link takes the name from the
current language's strings without falling back to Info.plist. (The Home Screen label was never
affected: it does fall back.) The link is new in M23 (S4, `2a56062`), so no shipped build had it. Fix:
`CFBundleName` = "Soundpost" in `ja` and `zh-Hans` too (one word in every language). Re-captured: 「Soundpost
のショートカット」 and 「Soundpost 快捷指令」, on iOS 27 and iOS 18.5.
Test `AppNameLocalizationTests` (2) reads the **built app's** compiled strings: each of en, ja, zh-Hans
carries `CFBundleName == "Soundpost"`, and the languages checked are exactly the app's localizations.

| Control (`cp` snapshot, restored and compared) | Caught by |
|---|---|
| the name in `en` only (as at HEAD) | `eachLanguageCarriesTheAppsName` |
| the name dropped in `ja` only | `eachLanguageCarriesTheAppsName` |
| the test's language list missing zh-Hans | `theLanguagesCheckedAreTheOnesTheAppShips` |

**`iPhone 17 Pro` (iOS 27)** — each tap below is from a screenshot of the result:
- **The section, EN / JA / ZH** (`-seedSampleData -screenshotScreen doors`): "Ways to start a capsule"
  / 「カプセルを始める方法」 / 「新建胶囊的方式」 with the Siri tip, the Shortcuts link, the widget
  line, the Control Center line and the footer. The tip's phrase is drawn by the system in the Siri
  language, English here, in all three: `Say "New capsule in Soundpost"`.
- **The Shortcuts link opens Shortcuts** — on Soundpost's page, one action, "New capsule"; the status
  bar's back link reads "◀ Soundpost".
- **The tip dismissal** (a normal launch, onboarding skipped): × on the tip → the row is gone and the
  section starts at the Shortcuts link, no empty row; Done; terminate; relaunch; Settings → still gone,
  no empty row.
- **The Home Screen widget**: the gallery lists Soundpost → "New capsule" with "Opens Soundpost ready
  to record. Nothing records until you tap the record button."; added. **Cold tap** (app terminated)
  → capture idle ("Up to 60 seconds. Tap to start."). **Warm tap** (same pid, backgrounded) → capture
  idle. At `accessibility-extra-extra-extra-large`, "New capsule" wraps to two lines, nothing cut;
  dark, tinted and clear Home Screens each draw the glyph and the words legibly.
- **A widget tap during a take**: recording, Home, widget → the app came forward with the take still
  running (0:26, nothing lost) — `.alreadyOpen`, as `drainCaptureRequest` is written. The plan's
  expectation ("leaving the app ends the take into review") is the device's behaviour: with no
  background audio mode iOS interrupts the session and `AudioRecorder.handleInterruption` finalizes
  into review. The simulator does not suspend a backgrounded app, so it cannot show that; it goes to
  H4. The take then hit 60 s and went to review on its own; discarded (never saved — this simulator is
  signed in to iCloud).
- **The control**: Control Center was empty after the restart; "Add a Control" → search "Soundpost" →
  "New capsule" added. **Cold tap** → capture idle. **Warm tap** (same pid) → capture idle — W7's fix
  holds on iOS 27.
- **Accessibility Inspector** on the small widget: not run — the Mac's console was locked, so no Mac app
  could be driven. The widget's VoiceOver shape stays covered by `WidgetExtensionTests` only.
- **The Lock Screen — witnessed.** `LOCK`, wake, then the plan's stationary `touch_path` hold (4
  samples, 1 s apart) at mid-screen: nothing. A 3 s long press: the poster switcher began (frame shrunk,
  preview clock "Tue Jan 9 9:41") but showed no buttons; after HOME it settled into the Lock Screen
  editor (Cancel / Done, "ADD WIDGETS"). Added both Soundpost faces (circular: the glyph; rectangular:
  glyph + "New capsule"); Done; the poster showed both. App terminated, `LOCK`, wake, **tap the
  rectangular face → Soundpost launched into capture idle**; terminated again, `LOCK`, wake, **tap the
  circular face → capture idle**. The simulator has no passcode, so "unlock first" is not shown; H4
  covers that on a phone. The Lock Screen claim in `description.txt:13` therefore stays.

**`Soundpost-iOS18` (iOS 18.5)**: the section in EN / JA / ZH (the staging scroll stops short of the
top on iOS 18 — the iCloud section shows above it; DEBUG-only, used only on the iOS 27 capture device);
the tip dismissal, then relaunch → still gone, no empty row; the control (already in its Control
Center): **warm tap** (same pid) → capture idle, **cold tap** → capture idle.

**The doors shot — dropped.** In every locale the iCloud section sits under the translucent navigation
bar at the top of the staged frame (EN "Capsules live only on this device…", the demo store's
local-only line), so by §4G it is not captured; `doors` stays out of `SCREENSHOT_SCREENS`.

**`iPhone 17 Pro Max` (iOS 27) — screenshots v2, captured.** `scripts/screenshots.sh` on the listed
device (`8C431EC3…`), shut down beforehand, so this pass booted it and shut it down after (H2).
Three things went wrong on the way, each recorded:
- **First boot: `bootstatus -b` failed** (`Status=4294967295, isTerminal=YES` after 9 s) and the script
  stopped with "did not boot". SpringBoard was crashing on that boot — `EXC_BREAKPOINT` in
  `-[FBSDisplayMonitor _initWithDisplays:…]` under `FBSystemShellInitialize` (no main display), every
  ~10 s; a later `simctl launch` then failed with "The system shell probably crashed". One `shutdown`
  + `boot` cleared it (SpringBoard running, no new crash report). Not erased.
- **The blank-frame check refused a drawn screen.** `zh-Hans/03-search` — four cards of waveforms and
  text — failed `screenshot_check.py` twice ("variance 23.3, mean 247 — an empty frame"). The check
  sampled an 8 × 8 grid of single pixels, and on a light screen all 64 can fall between the strokes;
  the same grid read the en-US gallery at 32.1, passing by luck, and the onboarding page at 14.6.
  Fixed: the default grid is 32 × 32. Measured on this capture's twelve shots: 390–1,600 (8 × 8 had
  23.3–1,236); a blank frame still reads 0. Tests `test_screenshot_check.py` (3) on synthetic PNGs:
  white with bars placed between the 8 × 8 rows reads 0 on the old grid (proving the fixture) and
  passes on the new one; uniform frames at 0, 128 and 255 are still refused. Control: the default
  grid back to 8 → `test_a_light_screen_with_thin_content_is_not_blank` fails.
- One zh-Hans capture shot showed the Dynamic Island's black pill above the capture sheet (the other
  locales did not); a re-capture did not, and all three locales' capture shots now match.

The set: `~/Library/Caches/Soundpost-build/screenshots-69/{en-US,ja,zh-Hans}/01-gallery … 04-capture`,
1320 × 2868, status bar 9:41 / full / charged. Read back by eye: every card time is daytime ("Calm
7:48 AM", "Energized 9:12 AM", the detail "Nov 10, 2026 at 3:40 PM"), no iCloud row, nothing about Pro.
Uploaded only in S7, by the path §4B.7 settled.

**Standing bars.** App uninstalled from the `iPhone 17 Pro` first (the pass had written its defaults),
then local `xcodebuild clean test` in place: **778 tests in 102 suites**, no warnings
(`check-warnings.sh`), localization 100% (363 strings); Python 188; store gate passes. `MIN_TESTS`
776 → 778, `MIN_PY_TESTS` 185 → 188.

**CI** `e504f39` ([run 43235224589](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43235224589)):
green — 778 tests (floor 778), Python 188 (floor 188), no warnings, Deno 22, `ALL PASS`; pinned 27B52 =
runner.

### Waiting on 1.12.0 (2026-11-13, 02:45)

1.12.0 still `WAITING_FOR_REVIEW` (submitted 11-10 09:29 UTC), so S7 has not started (§4H precondition).
Meanwhile, nothing that S7's precondition guards:
- **Signing, probed without a build** (global rule): `login.keychain-db` reports `no-timeout` (not
  "User interaction is not allowed"); a scratch copy of `/bin/echo` signed with the Apple Distribution
  identity and verified — with the console locked. Re-probed before S7's archive, not assumed.
- **`.git/index 3…13`** — `/usr/bin/trash` still refuses (513, console still locked). Left.
- **1.13.0 notes drafted** — `metadata/*/release_notes-1.13.0.txt`: the Settings section and the two
  About rows, in the app's own words for each (「カプセルを始める方法」, 「新建胶囊的方式」,
  「Soundpostを共有」 …), and that nothing records until the record button is tapped. No VoiceOver
  line — the widget was not checked with Accessibility Inspector (§4H: "only for the faces checked");
  nothing about delivery while S0 is unwitnessed. `release_notes.txt` and the version are untouched, so
  a rejected 1.12.0 would still get its own notes from `asc.py notes`. Checked by hand against the store
  gate's blocked terms and the zh-Hans full-width rule (the gate reads `release_notes-<version>.txt`
  only for the project's version, so it takes these over at S7's bump).

**CI** `eb1336e` ([run 43272862463](https://github.com/JasonYeYuhe/Soundpost/actions/runs/43272862463)):
green — 778 tests (floor 778), Python 188, no warnings, Deno 22, `ALL PASS`; pinned 27B52 = runner.

**`.git/index 3…13` — in the Trash (2026-11-14, Jason's word of 11-12).** The refusal (513) was not
the screen lock: it persisted with the console unlocked, and a fresh file in `.git/` or `build/`
trashed fine. It was the NAME — the same eleven copies renamed (`icloud-copy-index-<n>-<mtime>`)
trashed at once, so the Trash already holds items called `index 3` … `index 13`. Only `.git/index`
remains; `git status` clean, `git fsck` clean. 1.12.0 is still `WAITING_FOR_REVIEW` (submitted 11-10
09:29 UTC).
