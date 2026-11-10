# M22 — "A door on the Home Screen"

> Status: **PLAN, revision 2** (2026-11-10), after round 1 (Gemini 4 Argon via `agy`, and four
> independent review lenses — §12). Grounded at `a1d14c1` by six read-only investigations (capture
> doors, the new target's build and gate surface, the WidgetKit / App Intents APIs checked against
> the iOS 27.2 and 27.1 SDKs with `swiftc -typecheck` probes, the findings carried from M21, the store
> listing and copy, the content-widget option), plus fresh reads of Sentry, App Store Connect and the
> delivery database. Every claim names its file and line at `a1d14c1`; re-verify before you change
> anything. Starting facts: `docs/M22-START.md`. **1.11.0 (build 23) is live** — approved 2026-11-09,
> released on Jason's word 2026-11-10.

---

## 0. Goal & success statement

**What the data says (facts, 2026-11-10).** In the last 30 days Sentry saw 5 sessions on 1.10.0 and 2
on 1.11.0 (most likely App Review's devices); no crash, no new issue — the only events since 1.10.0
are the two offline `CloudKit sync error (domain 2, code 3, ck 3)` notices M21 S4 stopped reporting.
The delivery database is unchanged since M21: 3 pending jobs (one `no_tokens`, retried hourly), 2
production tokens, **no row has ever reached `status = 'sent'`**, and `0003_m21_hygiene.sql` is not
applied. Usage, not stability, is still the constraint.

**What M22 does.** Jason decided on 2026-11-08 (M21 §8 D2) that M22 builds the capture-frequency lever
the app's other doors do not cover: a **launcher widget** (Home Screen and Lock Screen) and an **iOS 18
Control Center control**, in **one new widget-extension target**, both opening capture **idle**
through the existing door — `CaptureRequests` → `NotificationCoordinator.requestCapture()` →
`CaptureLaunchRoute` (M20 S5). A launcher shows no capsule data, so it needs no App Group and no new
entitlement. Around it, M22 first makes the gates able to see a second target, fixes the release tool
that could not finish its own submission, and closes one privacy finding carried from M21 (the
lock-screen copy).

**Success** — all of these hold for the 1.12.0 build:

- A **Home Screen widget** (`systemSmall`) and two **Lock Screen widgets** (`accessoryCircular`,
  `accessoryRectangular`) named "New capsule" open Soundpost on the capture screen, idle — seen on
  the iOS 27 simulator **and on the iOS 18.5 simulator**, cold and warm, and recorded in §13.
- On iOS 18 and later, a **"New capsule" control** in Control Center does the same — seen on both
  simulators. (iOS 18–25 open an app through `openAppWhenRun` and iOS 26+ through `supportedModes`,
  so iOS 27 alone proves only half; **the listing claims nothing it was not seen to do** — §8 H2.)
- The existing doors (App Shortcut, Siri, Spotlight, Action Button, quick action) are **unchanged**
  and still open capture idle on iOS 27 with the extension installed — seen, not assumed.
- Every door sets the one capture request and nothing else; tests fail if any door records, opens
  capture around `CaptureLaunchRoute`, or calls `requestCapture()` directly.
- The extension compiles **exactly one** file from the app (the shared door file), links no package,
  carries **no entitlements**, keeps the app's version, build and 17.0 deployment target, imports
  nothing beyond SwiftUI, WidgetKit, AppIntents (and Foundation in the shared file), and its binary
  imports no network, `UserDefaults`, file-timestamp, boot-time or disk-space symbol — each pinned by a
  test or by the archive check.
- On iOS 17 the extension still loads and offers only the launcher: every iOS 18/26 symbol in the
  extension binary is a **weak** import (no iOS 17 runtime is installed — §7).
- The localization, warnings and debug-only gates derive targets, roots and binaries from the project
  file, check each target against **its own** catalogs and binary, and each is seen to fail on a
  fixture with a fault in a second target (`scripts/test_gates.py`, run by CI).
- The App Store archive contains the extension, signed by automatic signing, before release day (a
  dry archive to a scratch path, no upload, no dSYM upload).
- A personalized lock-screen notification never shows a sound label the in-app card would hide —
  neither without standing nor with listening off (M22-START item 5).
- Standing bars at every commit (§1.7).

**Not success:** a widget seen only in an Xcode preview; a control that opens the app to the gallery
but not to capture; "iOS 18 and later" in the listing with only iOS 27 seen; an extension catalog the
localization gate passes because the *app's* catalog has the key; a census or guard that iterates
files and passes when the folder is empty or missing (M15 §11P); "the control works" claimed from a
compile.

---

## 1. Non-negotiables (carried from M21 §1; rule 5 changed by D2)

1. **Calm, honest, literal copy** in EN · JA · ZH-Hans. Every sentence is literally true of the build
   for every state it can be shown in. No "quickly", "instantly", "never miss", no exclamation.
   *One accepted, pre-existing exception (M20 S5, shipped in 1.10.0):* "opens ready to record"
   describes the normal outcome of a door; the route deliberately waits through unfinished
   onboarding, declines under a capsule's own sheet, and leaves an already-open capture alone, so the
   door never interrupts what the person is doing. The widget and control inherit exactly that
   behaviour and that sentence.
2. **No counters, streaks, nags or engagement prompts. No new notification kind.** The widget shows
   no count, no date and no content.
3. **Free stays free; Pro stays hidden.** `ProOffer.isOnSaleInThisBuild` stays `false`
   (`Soundpost/Models/ProGate.swift:136`). No Pro door, string or StoreKit purchase in the widget or
   control (guideline 4.4: extensions contain no in-app purchase or marketing).
4. **No new CloudKit field or entity; no Console deploy.**
5. **One new target, exactly: the widget extension** (D2). No App Group, **no new entitlement on any
   target**, no deployment-target raise (iOS 17.0), no second extension, no UI-test target, no
   framework target. Zero new dependencies; the extension links no package (Sentry stays app-only).
6. **Delete no audio** except the user's own explicit delete.
7. **Standing bars at every commit:** warning-free on CI's Xcode (26.6) and on a clean local Xcode 27
   build (`xcodebuild clean test` in place); all tests green with the executed **count** confirmed
   (CI floor `MIN_TESTS`, now 723 — raise it with every step); i18n 100% **per target**; CI green on
   the pushed commit. Every new test is seen to fail against a deliberately broken implementation
   (`cp` snapshot, never `git checkout`; `-collect-test-diagnostics never`); record mutation → failing
   test in §13.
8. **Builds go through the shared package checkout** (`CLAUDE.md`, `scripts/lib/build_cache.sh`):
   one derived-data root for this checkout, reused across steps; never under `~/Documents`.
9. **Production data is read-only for the agent.** Supabase `gkjwsxotmwrgqsvfijzs` is shared with other
   apps; a migration or function deploy there is Jason's word. M22 deploys nothing to it.
10. **No new public door.** No URL scheme is registered unless the simulator proves the widget cannot
    open the app without one (§4C); if one is ever needed it reaches only `CaptureLaunchRoute`, and
    Jason is told before it ships.
11. **The existing doors do not change.** `OpenCaptureIntent` (and its App Shortcut) stays app-only,
    byte-for-byte, so the door 1.10.0 and 1.11.0 shipped cannot regress through the extension.

---

## 2. Scope

| Step | What | Size | Human step |
|---|---|---|---|
| **S0** | Witness one APNs send to a phone with a token (carried from M21) | S | **Jason, in parallel** |
| **S1** | Gates and tools that see each target: a project-file reader; per-target localization; warnings; debug-only per binary; one version; `verify_archive`; `asc.py` reuses its own draft; release-notes parity | M | none |
| **S2** | The shared door: `CaptureRequests` behind a protocol in one shared file with the control's intent and the widget URL; `.onOpenURL`; door censuses | M | none |
| **S3** | The widget extension: launcher widget (3 families) + iOS 18 control; its catalog; guards; witnesses on iOS 27 and 18.5; dry signed archive | L | **H2** (disk), **H3** (the identifier registration) |
| **S4** | The lock-screen copy obeys standing and the listening setting (M22-START item 5) | S | none |
| **S5** | 1.12.0 release: listing line, keywords, notes, store-gate claims; upload, submit | S | **Jason says release** |

**Drop order if tight:** S1's `apns.ts` line → S1's `asc.py` fix. Never drop S1's gates, S2, S3 or S4
(privacy). S5 does not start without both simulator witnesses (§8 H2).

---

## 3. Current state (grounded 2026-11-10 at `a1d14c1` — re-verify)

- **Release:** 1.11.0 (23) live since 2026-11-10 (approved 2026-11-09, released on Jason's word).
  `MARKETING_VERSION 1.11.0`, `CURRENT_PROJECT_VERSION 23` — set per target today
  (`project.pbxproj:283,301`). 723 tests in 95 suites, CI floor 723, 0 warnings, i18n 100%
  (Localizable, InfoPlist, AppShortcuts). Its archive is copied to
  `~/Library/Developer/Xcode/Archives/2026-11-08/`.
- **The capture door.** `SoundpostApp.init` installs `CaptureRequests.coordinator`
  (`SoundpostApp.swift:56,61`) before any scene connects. `CaptureRequests` (`CaptureLaunch.swift:61-68`)
  holds `static weak var coordinator: NotificationCoordinator?`; `request()` calls only
  `requestCapture()`, which sets `pendingCaptureRequest` and clears a waiting notification link
  (`NotificationCoordinator.swift:24,29-32`). The only other references to `CaptureRequests.coordinator`
  are the tests (`CaptureLaunchTests.swift:81-83`). The only consumer is
  `ContentView.drainCaptureRequest()` (`ContentView.swift:631-648`), which asks `CaptureLaunchRoute.decide`
  (`CaptureLaunch.swift:44-53`): `.wait` during onboarding or while Settings/a reveal is up,
  `.alreadyOpen` while capture is open (checked first, so a take is never disturbed), `.declined` under
  a capsule's own sheet, else `.present`. Drained from `refreshAndSync` (`:616,:624`),
  `.onChange(of: pendingCaptureRequest)` (`:174-176`), Settings dismissal (`:105`) and reveal dismissal
  (`:733`).
- **The doors today.** (A) `OpenCaptureIntent` — `openAppWhenRun = true`, `@available(iOS 26.0, *)
  supportedModes = .foreground`, `perform()` = `CaptureRequests.request()`
  (`Services/OpenCaptureIntent.swift:19-28`), with `SoundpostShortcuts: AppShortcutsProvider` in the same
  file (`:33-46`). (B) the quick action `com.soundpost.Soundpost.newCapsule` (`Soundpost-Info.plist:18-28`)
  through `SoundpostSceneDelegate` (`:16-33`), supplied by `SoundpostAppDelegate`
  (`Services/Delivery/SoundpostAppDelegate.swift:48-56`). (C) a notification tap
  (`NotificationCoordinator.swift:309-316`), which clears a waiting capture request (`:36-39`).
  **There is no URL door:** no `CFBundleURLTypes`, no `onOpenURL`, no `openURLContexts`, no associated
  domains. SwiftUI's own scene delegate implements `scene(_:willConnectTo:)`,
  `scene(_:openURLContexts:)` and `scene(_:continue:)` itself and forwards other selectors to the
  supplied delegate (read from the iOS 18.5 SwiftUI binary with `nm`) — so a URL is not guaranteed to
  reach `SoundpostSceneDelegate`; `.onOpenURL` is SwiftUI's documented receiver for a widget's URL.
- **Idle and foreground.** `CaptureViewModel.phase` starts `.idle` (`Capture/CaptureViewModel.swift:12`);
  `startRecording` is declared once (`CaptureViewModel.swift:129`) and called once, by the record button
  (`Capture/CaptureView.swift:148`); `showingCapture = true` is set at exactly four sites
  (`ContentView.swift:98,140,202,642`); `UIBackgroundModes` is only `remote-notification`
  (`Soundpost-Info.plist:11-14`), unguarded. Leaving the app ends a take (`AudioRecorder.swift:208-212`,
  "no background recording").
- **Guards that pin the doors.** `CaptureLaunchTests` reads `Soundpost/Services/OpenCaptureIntent.swift`
  by path and forbids `#if` in it (`SoundpostTests/CaptureLaunchTests.swift:105-113`); the scene
  delegate makes no window (`:117-125`); Info.plist's quick action equals `QuickAction.newCapsuleType`
  (`:128-135`). `ProOfferTests` walks `Soundpost/**` (`ProOfferTests.swift:172-186`);
  `SoundprintNeverLeavesTheAppTests` reads every file that sends content out of the app
  (`SoundprintDisplayTests.swift:175-208`).
- **Why `OpenCaptureIntent` must not be shared (verified):** compiled into an extension it fails on
  `CaptureRequests`, and `CaptureLaunch.swift` then fails on `NotificationCoordinator`. More
  importantly, the iOS 27.2 SDK documents that `openAppWhenRun = true` "generates an error if the app
  intent runs in an app extension", and iOS 27's `IntentExecutionTargets.default` may run an intent "in
  any available target" — a shared `OpenCaptureIntent` would give the shipped Siri/Shortcuts/Action
  Button door a second, failing home. `allowedExecutionTargets` cannot be used (iOS 27 SDK only; CI
  builds with the iOS 26 SDK).
- **APIs (verified against the iOS 27.2 and 27.1 SDK swiftinterfaces and by probes):**
  - A `WidgetBundle` with a `StaticConfiguration` launcher and `if #available(iOS 18.0, *) { Control() }`
    compiles at a 17.0 target in Swift 5 and 6 modes (`WidgetBundleBuilder.buildLimitedAvailability`,
    SwiftUI swiftinterface :28138, :28168-28188). An unguarded control, a plain `if`, and `if #available
    … else` all fail. **Xcode's own widget template lists the control unguarded and breaks at 17.0.**
  - `ControlWidget` is iOS 18.0. `ControlWidgetButton(action:)` has an overload for any `AppIntent` and
    one for an `OpenIntent`, documented as "a button template for a control that launches an app"
    (WidgetKit :1303-1305). Apple's controls article: use `OpenIntent` to open the app, and set the
    intent's target membership to "both the app and the widget extension". `OpenIntent` requires a
    `target` of an `AppEnum`/`AppEntity` type (AppIntents :16592-16603); a one-case `AppEnum` compiles;
    `isDiscoverable = false` (iOS 17) keeps it out of Shortcuts. Probe: a shared file with the protocol
    hook, `CaptureRequests`, `CaptureDoor` and such an intent compiles at 17.0 with
    `-application-extension` in Swift 5 and 6.
  - `widgetURL(_:)` (iOS 14; swiftdoc "Sets the URL to open in the containing app") makes a small or
    accessory widget one tap target. `containerBackground(for: .widget)` is required from iOS 17. iOS
    rendering modes are `fullColor`, `accented`, `vibrant`; `widgetAccentable()` iOS 16. Apple's
    interactivity article: a widget **button** should do more than open the app — use `widgetURL` or
    `Link` to just open it.
  - `disfavoredLocations(_:for:)` (iOS 17) lists a widget under "Other" in the gallery — it does not
    hide it. `.carPlay` is iOS 26 (WidgetKit :1629-1634); `.iPhoneWidgetsOnMac` is iOS 17 (:1611-1616).
  - Not used (iOS 27 SDK only): `allowedExecutionTargets`, `IntentExecutionTargets`,
    `systemExtraLargePortrait`.
  - A control's `displayName`/`description` take `LocalizedStringResource`, whose default bundle is
    `.main` — in the extension, the `.appex`. **The extension needs its own catalog for every key of
    every file it compiles, including the shared one.**
  - Compiled for iOS 17.0, every iOS 18/26 symbol (`ControlWidget`, `StaticControlConfiguration`,
    `WidgetLocation.carPlay`, `IntentModes`) is a weak import (`nm -m` of a probe object).
- **The project file** is hand-written (zero-padded IDs, `objectVersion = 77`, `compatibilityVersion
  "Xcode 16.0"`, `project.pbxproj:6,147,158`), two targets with one synchronized folder each
  (`:29-38`), no exception sets, no embed phase (`:84-88`); Sentry reaches the app through
  `packageProductDependencies` (`:97-99`). `SWIFT_VERSION = 5.0` everywhere; no strict-concurrency or
  default-isolation settings. Xcode 27.2 knows project classes the xcodeproj gem rejects
  (`…TargetMembershipExceptionSet`); Xcode's New Target dialog would bring Xcode-26-era template
  settings and versions 1.0/1. The gem (1.27) round-trips this file with 57 lines of harmless churn and
  adds a full extension target as a clean ~100-line change in a scratch copy.
  `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions` means "excluded" for a target
  that owns the folder and — per the grounding and the gem, **disputed by review R1-1** — "included"
  for a target that does not; the S3 build settles it (§4D).
- **Gates that a second target would slip past (each shown with a scratch fixture):**
  - `check-localization.sh` scans only `Soundpost/**` (`:33,:188`); derives each catalog's required
    languages from that catalog alone, so **an English-only catalog prints "100% translated"**
    (`:46-51`); pools every catalog's keys into one `known` set (`:112-114`), so a literal in one target
    passes on another target's catalog; does not scan `.configurationDisplayName(`, `.description(`,
    `.displayName(`, `LocalizedStringResource … = "…"` or `IntentDescription(` (`:99-109`, `:162-167`).
    `AppShortcuts.xcstrings` has only `ja` and `zh-Hans` localizations (`en` is its source).
  - `check-warnings.sh` filters on `/(Soundpost|SoundpostTests)/` (`:21,:38`), which matches the
    checkout's own name (so it covers the `.xcodeproj` and root plists today, and a widget folder only by
    accident); path-less build-system warnings carry `(in target 'X' from project 'Soundpost')`; one
    path-less line is known noise (`appintentsmetadataprocessor … Metadata extraction skipped`).
  - `check-debug-only.sh` inspects only `Soundpost.app/Soundpost` (`:104-107`) with an app-only premise
    string, `"Soundpost heard"` (`:121-124`); the `.app` already holds two Mach-O files (the app and
    `Sentry.framework`), so a count of executables would not notice a missing `.appex`.
  - `build-upload-asc.sh` deletes `build/Soundpost.xcarchive` before archiving (`:27,:92`), uploads
    dSYMs to Sentry in archive mode too (`:123-129`), and its dSYM gate accepts any `.dSYM` (`:125`);
    `RELEASE_PREFLIGHT_OVERRIDE` disables the SHA and dSYM checks (`:108,:131`). The preflight refuses
    today on iCloud conflict copies (`metadata/* 2`, another session's `.claude/* 2.lock`;
    `release-preflight.sh:52-59`).
  - Versions: `release-preflight.sh:36-43`, `asc.py:121-131` and `check-store-metadata.py:89` count
    *distinct values*, so an extension configuration with no version at all still reads as one value.
  - `check-store-metadata.py:98` skips the release-notes parity check when
    `release_notes-<version>.txt` does not exist.
- **Signing.** Release archives and exports use automatic signing with `-allowProvisioningUpdates` and
  the ASC API key (`build-upload-asc.sh:85-101,:141-145`; ExportOptions plists pin no profiles), the
  same flags Stride ships its widget with; doing so **registers** the extension's identifier and
  profiles in the team (H3). CI's `CODE_SIGN_IDENTITY="-"` overrides apply to every target
  (`ci.yml:198-199`).
- **Strings to reuse (all translated):** "New capsule" / 新しいカプセル / 新建胶囊
  (`Localizable.xcstrings:1782`). "Start recording" must **not** be used — the widget does not record.
- **Store gate traps:** `\bunlock`, 解锁 and "in-app" are blocked while Pro is off sale
  (`check-store-metadata.py:121-148`); the blocked-word scan reads `release_notes.txt` only (`:130,:139`).
- **Carried findings (M22-START), re-verified:**
  - Item 5 holds and is broader than stated: the digest copies the stored label whenever rejections
    are readable (`NotificationCoordinator.swift:240`), ignoring both standing **and** the listening
    setting; `isEnabled` only feeds `contentVersion` (`:212,:248`). Every other place a label is shown
    is gated on `mayReveal` (cards, detail, resurface, search, filters, almanac, export, share).
  - Item 2's after-due half holds, but its fix is near-useless and harmful (§12 F1/F2) — left.
  - Item 9 holds — Apple refuses to cancel an unsubmitted draft (M21 §13 S6).
  - New, left with item 6: an unseal that cannot reach the server keeps its stamp
    (`CapsuleStore.swift:276-279`, `SealDeliveryService.swift:136-138`) and a later re-seal clears it,
    so a re-seal inside 24 h orphans the old far job.
  - Item 4's premise is wrong: onboarding has **no** listening page (`OnboardingView.swift:33-77`).
- **Disk:** 17–21 GB free (other sessions write too); the global rule forbids booting a simulator below
  30 GB. `iPhone 17 Pro` (iOS 27) is booted; `Soundpost-iOS18` (iOS 18.5) is shut down.

---

## 4. Design decisions

### 4A. S0 — the push witness (carried, unchanged)

M21 §4A, still owed. 1.11.0 fixes the last-day defect, but opening the app inside the seal's last 24
hours still hands the seal back and **cancels the server job** — so the witness instructions are
unchanged: confirm a token row first (read-only); seal a capsule in the calendar to two days ahead on
the App Store build with notifications allowed; do not open Soundpost on any device of that iCloud
account from 24 hours before the due time until the push arrives; read `status = 'sent'` **before**
the tap (opening the app after due deletes the row); then tap it from a killed app. S0 gates D11 and
every future server change.

### 4B. S1 — gates and tools that see each target

The gates must cover the extension **before** it exists, so S3 cannot land unseen — and must not be
edited to name it (a gate that needs a hand-added path forgets the next one).

1. **One project reader.** `scripts/lib/project_model.py` parses `project.pbxproj` with a
   brace-matching parser (never a line regex — Xcode writes `exceptions = (…)` between `isa` and
   `path`), and prints JSON: every native target with its `productType`, product name and executable
   path inside the `.app`, its `fileSystemSynchronizedGroups` roots, the files added or excluded by
   `membershipExceptions` (excluded for the owning target, included for any other), its build settings
   and the project-level settings. Every gate below reads it; it fails if a root it reports does not
   exist or holds no Swift file (M15 §11P), and if there is no application target.
2. **`check-localization.sh` — per target.** For each app and app-extension target: its sources (its
   roots plus files a membership exception adds to it) are checked against **its own** catalogs (the
   `.xcstrings` in its roots or added to it), never another target's; a target with localizable
   literals and no `Localizable.xcstrings` fails. Required languages are the **union of every catalog's
   non-source languages** (ja, zh-Hans today), so a new English-only catalog fails while
   `AppShortcuts.xcstrings` (en is its source) stays green. Patterns gain `.configurationDisplayName(`,
   `.description(`, `.displayName(`, `IntentDescription(` and literals assigned to
   `LocalizedStringResource` (stored and computed); they must find today's `OpenCaptureIntent` strings.
3. **`check-warnings.sh`:** count a warning whose path is under the checkout (`$PROJECT_DIR/`) and not
   under `SourcePackages` or `DerivedData` — tests included, and the same rule inside the
   macro-expansion pairing — plus path-less lines that end `from project 'Soundpost')`; the known
   App Intents metadata noise stays excluded (re-run on `build/B20-test.log` to show it).
4. **`check-debug-only.sh` — per binary.** From the project reader, the expected executables
   (`Soundpost.app/Soundpost`; `PlugIns/<P>.appex/<P>` for each extension) must each exist, and each has
   its **own premise anchor** (the app: "Soundpost heard"; the extension: its widget kind string), so an
   empty or wrong binary cannot pass the absence checks.
5. **One version.** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` move to the project-level Debug
   and Release configurations; a check (in `check-store-metadata.py`, which CI runs) asserts no target
   overrides either and no `*-Info.plist` hard-codes `CFBundleShortVersionString`/`CFBundleVersion`. The
   existing `sort -u` parsers keep working; the S5 bump edits two lines.
6. **`verify_archive`** — a separate entry point, `scripts/verify-archive.sh <path.xcarchive>`, fatal in
   every mode and **never** covered by `RELEASE_PREFLIGHT_OVERRIDE`, called by `build-upload-asc.sh`
   after archiving: every expected executable (from the project reader) is present; each embedded
   bundle's versions equal the app's; the extension point is `com.apple.widgetkit-extension`; the
   extension links no Sentry; `nm -u` of the extension imports no network (`URLSession`, `NWConnection`,
   `CFNetwork`), `UserDefaults`/`NSUserDefaults`, file-timestamp, boot-time (`systemUptime`,
   `mach_absolute_time`) or disk-space symbol; every iOS 18+ WidgetKit/AppIntents symbol it imports is
   weak; `Soundpost.app.dSYM` exists **by name**. Proven against a doctored copy of the live 1.11.0
   archive in the scratchpad (before S3) and against S3's dry archive.
7. **`build-upload-asc.sh`** gains `ARCHIVE_PATH`/`EXPORT_PATH` overrides (so a dry run never deletes
   `build/Soundpost.xcarchive`) and skips the Sentry dSYM upload when `SENTRY_AUTH_TOKEN` is unset in
   archive mode.
8. **`asc.py submit` reuses its own draft (M22-START item 9).** `READY_FOR_REVIEW` leaves
   `asc_policy.CANCELABLE`. New policy: `reusable_draft(submissions)` returns the one `READY_FOR_REVIEW`
   with **no** `submittedDate` (refuses if two); a `READY_FOR_REVIEW` **with** a `submittedDate` (a
   reopened rejection) is routed to `Refusal(THREAD_KEEPING_PATH)` — never cancelled, never
   `submitted: true`; the rejection refusal stays ahead of any reuse. `draft_items_plan(items,
   version_id)` → `add` / `submit` / refuse when the draft holds another version or an item whose
   version id cannot be read (the items fetch asks for `include=appStoreVersion`, which returns each
   item's version linkage).
   `cmd_submit` reuses the draft instead of cancel + create; `cmd_cancel` stops waiting on it. Tests:
   the prototype's cases plus the submitted-date case, rewritten `test_drafts_may_be_cancelled` and
   `test_a_clean_slate_proceeds`, and an AST guard that the POST to `/v1/reviewSubmissions` sits only in
   the create branch.
9. **Release-notes parity:** `check-store-metadata.py` fails when `release_notes-<MARKETING_VERSION>.txt`
   is missing for a locale (`:98` skips today), and runs the blocked-word scan on the versioned file
   too.
10. **`apns.ts` (item 7):** `body: new Uint8Array(opts.payloadBytes)` at `:132` (identical at runtime)
    and whatever else `deno check` reports on the four import-free files (`apns.ts`, `auth.ts`,
    `payload.ts`, `state.ts`; Gemini flags `der` at `:64-67`). CI runs `deno check` on those four files
    **before** `deno cache` and reports a failure as a `::warning::`, not a red build: its job is to tell
    the next function deploy what Homebrew's unpinned Deno now rejects; `deno test` keeps `--no-check`
    (M21 §13 S5). No deploy (§1.9).

**Proof:** `scripts/test_gates.py` (stdlib only; discovered by CI's existing `unittest discover -s
scripts`, `ci.yml:110`) builds temp trees from fixtures — a second target with an untranslated literal
whose key exists only in the other target's catalog; an English-only catalog; an `exceptions = (…)`
root group; a widget-path warning in a checkout not named `Soundpost`; a build log with a path-less
target warning; an `.app` with an empty appex executable; an extension configuration with no version;
a doctored archive — each seen to fail the old gate (or crash it) and the new gate only while the
fault is present; recorded in §13.

### 4C. S2 — the shared door (app target only; no new target yet)

**One new shared file, `Soundpost/Services/CaptureDoor.swift`** — the only app file the extension will
compile. It imports only `AppIntents` and `Foundation`, has no `#if`, and holds:

- `@MainActor protocol CaptureRequestHandling: AnyObject { func requestCapture() }`;
- `CaptureRequests`, **moved** from `CaptureLaunch.swift`, now `static weak var coordinator: (any
  CaptureRequestHandling)?` — still weak, still installed in `SoundpostApp.init`;
- `CaptureDoor.newCapsuleURL` and the pure matcher `CaptureDoor.opensCapture(_ url: URL) -> Bool`
  (exact scheme, host and empty path; any query, fragment, user, port or extra path matches nothing);
- `NewCapsuleControlIntent: OpenIntent` — `static let isDiscoverable = false`; `title` "New capsule";
  `@Parameter(title: "Capsule") var target: CaptureDestination` (a one-case `AppEnum`, displayed "New
  capsule"), set by an explicit `init()` — `@Parameter` synthesizes no `init(target:)` (R2-3);
  `perform()` = `CaptureRequests.request()`; `openAppWhenRun = true` and the iOS 26 `supportedModes`
  declared explicitly, with no `#if`, mirroring `OpenCaptureIntent`. Every string reuses an existing
  translated key ("New capsule", "Capsule", the intent description).

`OpenCaptureIntent.swift` and `SoundpostShortcuts` are **not touched** (§1.11). `extension
NotificationCoordinator: CaptureRequestHandling {}` lives app-only. In the extension the hook is always
nil and no capture code exists.

**The widget's entry.** The launcher will use `widgetURL(CaptureDoor.newCapsuleURL)`. The app receives
it with **`.onOpenURL`** on `RootView`'s content, outside the onboarding switch (so a tap during
onboarding queues the request, which then waits), calling `CaptureRequests.request()` only when
`CaptureDoor.opensCapture` matches. **No `CFBundleURLTypes`** — a widget's URL is delivered to its
containing app; S3's witness proves it. If it does not arrive: (2) `.onContinueUserActivity` for the
widget's `NSUserActivity` (its `userInfo` carries the widget kind; SwiftUI delivers cold and warm);
(3) only if both fail, register the scheme (a public door that still reaches only `CaptureLaunchRoute`)
and tell Jason before it ships (§1.10). Whichever path works is the one the guard pins (§13 records the
deviation if S3 changes it).

**Tests (S2).**
- *Behaviour:* a fresh coordinator in the hook; `try await NewCapsuleControlIntent().perform()` sets
  only `pendingCaptureRequest` and clears a waiting link; the route still
  answers `.wait` during onboarding and `.present` when ready; `OpenCaptureIntent().perform()` behaves
  exactly as before.
- *Matcher table:* only the exact URL matches; prefixes, `?record=1`, fragments, other schemes and hosts,
  trailing slashes match nothing.
- *Censuses* over every **non-test** root the project reader reports (each first asserts its anchor was
  found, so an empty scan fails), counting **call sites**, not declarations: `startRecording(` is called
  once, in `CaptureView.swift`'s record button; `showingCapture = true` at exactly the four known
  sites; `requestCapture()` is called only by `CaptureRequests`; `UIBackgroundModes ==
  ["remote-notification"]` in `Soundpost-Info.plist`, and no `UIBackgroundModes` in any other
  `*-Info.plist` or `INFOPLIST_KEY_UIBackgroundModes` setting.
- *Shape:* the shared file imports only `AppIntents`/`Foundation`, contains no `#if`, no
  `AppShortcutsProvider`, no `startRecording`; `OpenCaptureIntent.swift` is unchanged (its existing
  guard, plus a hash of the file pinned in the test); `RootView` has the `.onOpenURL` that calls the
  matcher.

### 4D. S3 — the widget extension

**Shape.**

| Item | Value |
|---|---|
| Folder | `SoundpostWidget/` at the repo root, a synchronized folder owned by the extension only (outside `Soundpost/`, so its `@main` never compiles into the app) |
| Target | `SoundpostWidgetExtension` (`PRODUCT_NAME`), `com.apple.product-type.app-extension`, bundle id `com.soundpost.Soundpost.Widgets` |
| Shared file | `Soundpost/Services/CaptureDoor.swift` only. Primary: one `PBXFileSystemSynchronizedBuildFileExceptionSet` on the `Soundpost` folder with `target = <extension>`. **If the build shows that does not add the file** (review R1-1), fallback: move it to a `Shared/` folder synchronized into **both** targets (no exception set). The extension's own `fileSystemSynchronizedGroups` is exactly `[SoundpostWidget]` (or `[SoundpostWidget, Shared]`). |
| Info.plist | `SoundpostWidget-Info.plist` at the repo root (house rule, `Soundpost-Info.plist:5-10`): an `NSExtension` dictionary with `NSExtensionPointIdentifier = com.apple.widgetkit-extension`; `CFBundleDisplayName = Soundpost`; no version keys |
| Settings | copied from the app: Automatic signing, team `KHMK6Q3L3K`, iOS 17.0, Swift 5.0, `SWIFT_EMIT_LOC_STRINGS = YES`, device family 1, `GENERATE_INFOPLIST_FILE = YES`; different: `APPLICATION_EXTENSION_API_ONLY = YES`, `SKIP_INSTALL = YES`, extension runpaths; **absent:** entitlements, Sentry, app icon, asset catalog, encryption and usage keys, versions (inherited from the project, S1), any template concurrency/isolation setting |
| App target | an "Embed Foundation Extensions" copy phase (`dstSubfolderSpec = 13`), build file with `ATTRIBUTES = (RemoveHeadersOnCopy, )`, a target dependency; the scheme needs no change (`buildImplicitDependencies = YES`) |
| Catalog | `SoundpostWidget/Localizable.xcstrings` (en, ja, zh-Hans) holding **every key of every file the extension compiles**, the shared file's included; a test holds each key's three translations **equal** to the app catalog's |
| Privacy manifest | none: the extension calls no required-reason API — pinned by a source guard over the extension folder **and** the shared file, and by `verify_archive`'s `nm -u` |
| Look | no asset catalog: the glyph and text use the system's primary and accent colours, so tinted, clear and vibrant renderings stay legible without a custom palette |

**How the target is added.** Hand-edited in the file's own zero-padded-ID style, following the object
list the grounding produced. Validated by `plutil -lint`, by the S1 project reader (targets, roots,
exceptions, settings), by a read-only xcodeproj-gem open (never `save`), and by a diff showing
`objectVersion`, `compatibilityVersion`, `preferredProjectObjectVersion` and the package section
byte-identical. Then a clean local build on Xcode 27.2 and CI green on 26.6. The gem's `add` path is the
fallback (harmless churn). Xcode's New Target dialog is not used.

**The launcher widget.** `StaticConfiguration(kind: "com.soundpost.Soundpost.widget.newCapsule")`, a
provider with one entry and policy `.never`, families `.systemSmall`, `.accessoryCircular`,
`.accessoryRectangular`. Display name "New capsule"; description: one new key — EN "Opens Soundpost
ready to record. Nothing records until you tap the record button." (JA, ZH in §4F) — because the
intent's "Recording starts only when you tap" reads ambiguously next to something you tap. Faces: the
`waveform` glyph (`widgetAccentable()`) and, where there is room, "New capsule"; the circular face is
the glyph with "New capsule" as its accessibility label. `containerBackground(for: .widget)` with a
system fill. `widgetURL(CaptureDoor.newCapsuleURL)` on every family. Disfavoured locations (D14):
CarPlay (iOS 26+, built under `#available`) and iPhone widgets on Mac — they move to the gallery's
"Other" section, they are not hidden. **Kinds never change after release** (a renamed kind deletes
people's placed widgets) — pinned by a test.

**The control.** `@available(iOS 18.0, *) StaticControlConfiguration(kind:
"com.soundpost.Soundpost.control.newCapsule") { ControlWidgetButton(action:
NewCapsuleControlIntent()) { Label("New capsule", systemImage: "waveform") } }`,
display name "New capsule", the same description.

**The bundle.** `@main struct SoundpostWidgets: WidgetBundle { LauncherWidget(); if #available(iOS
18.0, *) { NewCapsuleControl() } }` — exactly the probe that compiles at 17.0.

**Guards** (the extension cannot be unit-tested itself; its tests run against the app host): the
extension folder exists and holds the expected files; `SoundpostWidget/` sources import only `SwiftUI`,
`WidgetKit`, `AppIntents`; they never name `CaptureRequests`, `NotificationCoordinator`,
`startRecording`, `\bPro\b`, `Pro[A-Z]\w*`, `StoreKit`, `StoreService`, `UserDefaults`, `@AppStorage`;
they use `widgetURL` and no `Button(intent:)` or `Link`; the control sits behind `if #available(iOS
18.0, *)` in the bundle; the two kinds equal pinned constants; the extension's sources and the shared
file are added to `SoundprintNeverLeavesTheAppTests`' inputs. Project (via the S1 reader): the
extension's roots, its one added file, no `CODE_SIGN_ENTITLEMENTS`, no package product, no version
override, deployment target 17.0, `APPLICATION_EXTENSION_API_ONLY = YES`, `SKIP_INSTALL = YES`, and the
app embeds it.

**Seeing it work (recorded in §13).** On `iPhone 17 Pro` (iOS 27, by UDID, under
`/tmp/lock-iphone-17-pro`) **and** `Soundpost-iOS18` (iOS 18.5, under its lock — only once §8 H2 frees
the disk): add the small widget, a Lock Screen widget and the control; tap each from a cold and a warm
launch → capture opens idle. With onboarding unfinished → it waits, then opens after onboarding. With a
capsule's edit sheet open → declined, nothing opens over it. **During a take:** a widget tap means
leaving the app, which ends the take and moves it to review (nothing lost) — the expected result; the
control pulled down over the running app → `.alreadyOpen`, the take continues. The existing doors on
iOS 27 with the extension installed: "New capsule" from Shortcuts and Spotlight, cold and warm, opens
capture idle, and Shortcuts lists "New capsule" once. Then a **dry signed archive** to
`~/Library/Caches/Soundpost-build/dry-archive/` with `SENTRY_AUTH_TOKEN` unset (`build-upload-asc.sh
archive` with the S1 overrides; no upload, no dSYM upload, `verify_archive` passes); keychain probes first
(global CLAUDE.md). It registers `com.soundpost.Soundpost.Widgets` in the team (H3). If the preflight
refuses on the conflict copies (D9), the override is used for the preflight only — `verify_archive` is
never overridable.

### 4E. S4 — the lock-screen copy obeys standing and the listening setting

`NotificationCoordinator.swift:212` reads `SoundAnalysisPreferences.mayReveal` (listening on **and**
standing) instead of `isEnabled`, and the digest (`:240`) carries a soundprint only when that is true —
the same rule every card uses. The token in `contentVersion` changes with it, so the next sync after
an upgrade re-issues bodies that 1.11 scheduled with a label (`p1` → `p1n` for a device without
standing). **When standing is granted later** (at a launch's standing step, which runs after that
launch's re-sync — `LaunchSequence.swift:172-195` — or on a consent row arriving through a remote
change, which does not record standing until the next launch), labels appear from the **next** sync:
the lag only ever shows *less*, never more, and the M21 launch order is not changed. Tests: a pure
test on an extracted `digests(…, reveal:)` covering listening-off-with-standing and
listening-on-without-standing; a source guard that the coordinator derives `reveal` from `mayReveal`;
a content-version test for the re-issue; controls: `isEnabled` put back; the `:240` gate removed.

**Left, with reasons (recorded, not built):**
- **Item 2 (after-due cancel):** the skip would almost never apply (a seal handed back in its last day
  has no stamp left), and for `no_tokens`/retry jobs it would bring back a push hours after the person
  opened the capsule (review F1/F2).
- **The offline unseal → re-seal orphan (new) and item 6 (cancels keyed by id):** both are the stale-
  cancel family; a client-only enqueue widens item 6's window (a device offline for days could cancel a
  sibling's later re-seal). One server-side fix (a stamp-keyed cancel) closes both — M23, with B1.
- **Item 1 (B2):** D11. **Item 3:** D12. **Item 4:** D13 (there is no listening page).

### 4F. S5 — the release (1.12.0, build 24)

1.11.0 is live, so nothing blocks a new version record. `MARKETING_VERSION 1.12.0`, build 24, at the
project level (S1). **S5 does not start until both simulator witnesses are in §13.**

- **Description** (each locale's capture-doors line, `metadata/*/description.txt:13`; passes the store
  gate in two scratch runs):
  - EN: "- Start a new capsule from Siri, Shortcuts, Spotlight, the Action Button, the Home Screen icon,
    a Home Screen or Lock Screen widget, or Control Center (iOS 18 and later) — it opens ready to
    record, and records only when you tap"
  - JA: 「- Siri、ショートカット、Spotlight、アクションボタン、ホーム画面のアイコン、ホーム画面やロック画面のウィジェット、コントロールセンター（iOS 18以降）から新しいカプセルを始められます——録音の準備ができた状態で開き、録音はタップしたときだけ始まります」
  - ZH: 「- 通过 Siri、快捷指令、聚焦搜索、操作按钮、主屏幕图标、主屏幕或锁定屏幕小组件，或控制中心（iOS 18 或更高版本）新建胶囊——打开即可录音，只有在你点按时才开始录音」
- **Keywords:** append ",widget" / ",ウィジェット" / ",小组件" (96, 52, 45 of 100).
- **Store-gate claims** added in this commit, now that the listing makes them: "widget" / ウィジェット /
  小组件 and "Control Center" / コントロールセンター / 控制中心.
- **Release notes** (`release_notes-1.12.0.txt`, copied to `release_notes.txt` after the bump; the
  gate now scans both):
  - EN: "• Start a new capsule from a widget on your Home Screen or Lock Screen. Tapping it opens
    Soundpost ready to record; nothing records until you tap the record button." / "• On iOS 18 and
    later, you can also add a "New capsule" control to Control Center. It opens Soundpost the same way."
  - JA: 「• ホーム画面やロック画面のウィジェットから新しいカプセルを始められるようになりました。タップすると Soundpost が録音の準備ができた状態で開き、録音ボタンをタップするまで録音は始まりません。」/「• iOS 18以降では、コントロールセンターに「新しいカプセル」コントロールを追加することもできます。同じように Soundpost を開きます。」
  - ZH: 「• 现在可以通过主屏幕或锁定屏幕上的小组件新建胶囊。点按后，Soundpost 会打开并准备好录音；在你点按录音按钮之前，不会开始录音。」/「• 在 iOS 18 或更高版本上，还可以把「新建胶囊」控制添加到控制中心。它会以同样的方式打开 Soundpost。」
  - S4 is not mentioned (a user who never had standing sees no change they could name). Placing the
    control on the Lock Screen or the Action Button is mentioned only after it was seen on a device.
- **The widget's new description key:** EN as in §4D; JA 「Soundpost を録音できる状態で開きます。録音ボタンをタップするまで録音は始まりません。」;
  ZH 「打开 Soundpost 并准备好录音。在你点按录音按钮之前，不会开始录音。」
- **Not changed:** subtitle, promotional text (D6 still open; EN is at 161/170), screenshots (no tool
  can place a widget; `04-capture.png` already shows where it leads), privacy label and policy (§6).
- Clean Xcode 27 gate, CI green, `release-preflight.sh`, `build-upload-asc.sh` (now with
  `verify_archive`), `asc.py create-version 1.12.0` / `notes` / `description` / `keywords` / `attach 24`
  / read back `MANUAL` / `submit`, then STOP. `asc.py release` only on Jason's word.

---

## 5. Work breakdown

1. **S0** runs whenever Jason starts it; it gates only D11.
2. **S1** → **S2** → **S3** → **S4** → **S5**. S3 depends on S1 (the gates must see it) and S2 (the
   shared file). S4 is independent and may move before S3 if S3 waits on H2 or on signing.
3. S5 waits for both simulator witnesses (H2); it does not wait for S0 or D3.

---

## 6. Privacy / legal delta

- The launcher and the control show only "New capsule" and a glyph: no capsule content, count or date,
  on the Home Screen, the Lock Screen, StandBy or Control Center. Nothing is read, stored or sent: the
  extension has no App Group, no entitlement, no network symbol and no Sentry (`verify_archive`).
- **App Privacy label unchanged by M22; privacy policy unchanged** (it does not list the ways into
  capture). M21 D7 (Sentry's city-level geo vs a label that declares no location) is still open.
- A widget or control tap on a locked phone requires unlocking first (Apple's behaviour; not visible on
  a simulator without a passcode — checked on Jason's phone if D8 is yes); it opens capture idle, like
  every other door.
- S4 *reduces* what a personalized lock-screen notification can show.
- No URL scheme is registered unless §4C's fallback (3) is reached and Jason is told.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| The hand-edited project file breaks Xcode 26.6 on CI | `objectVersion`/compatibility unchanged; the S1 reader and a read-only gem open validate it; no Xcode-27-only classes; CI is the authority before anything else lands |
| A membership exception does not add the shared file to a target that does not own the folder (R1-1) | the extension fails to compile (the bundle names `NewCapsuleControlIntent`) — the build settles it; fallback `Shared/` folder in both targets |
| The widget's URL never reaches `.onOpenURL` without a registered scheme | §4C's fallback order, settled on the simulator, recorded; a scheme only with Jason told |
| The control's `OpenIntent` does not open the app | Apple's documented pattern (both targets); witnessed on iOS 18.5 and 27 |
| The shipped Siri/Shortcuts door regresses | `OpenCaptureIntent` is app-only and pinned unchanged (§1.11); witnessed with the extension installed |
| A door records or bypasses the route | censuses over every non-test root with anchors; the extension contains no capture code |
| The extension's strings ship untranslated | per-target localization (S1), the catalog-equality test (S3) |
| A second binary escapes the debug-only or dSYM gate | per-binary executables and premises (S1); `Soundpost.app.dSYM` required by name |
| A dry archive deletes a release archive or uploads dSYMs | `ARCHIVE_PATH`/`EXPORT_PATH` overrides; no Sentry token in the dry run; 1.11.0's archive already copied out |
| Automatic signing cannot register the extension's identifier with the API key | dry archive in S3, before release day; if it fails, Jason registers it in the portal (H3) |
| iOS 17 behaviour untested (no runtime; installing one is Jason's call) | compile at 17.0 in Swift 5 and 6 modes; weak-import check in `verify_archive`; recorded as untested |
| The iOS 18–25 path untested if the disk stays under 30 GB | H2 blocks S5; the listing claims nothing unseen |
| Machine load makes local runs flaky (M21: load average 40+) | CI is the authority; known local-only flake `VideoGateTests.playbackStaysFree` |
| S4 shows labels one sync late after standing is granted | fail-closed by design (shows less, never more); the launch order is unchanged |

---

## 8. Human-in-the-loop (needs Jason)

**Steps**
- **H2 — free disk for the simulator witnesses:** the Mac has 17–21 GB free; the global rule forbids
  booting a simulator under 30 GB, and S3's witness needs the iOS 18.5 simulator (and the iOS 27 one
  re-booted if it shuts down). Emptying the Trash (⌘⇧⌫) should be enough. **S5 waits for it.**
- **H3 — the extension's identifier:** S3's dry archive lets automatic signing register
  `com.soundpost.Soundpost.Widgets` and its profiles in your developer account (a permanent, private
  account change). If the API key may not register identifiers, you register it in the portal.
- **S0** push witness (§4A). **S5** "release" — the only public, irreversible action.

**Decisions** (M22 assumes the default in **bold**)
- **D1 Pro:** **keep hidden** (unchanged).
- **D3 Server hygiene migration (carried):** **apply `0003_m21_hygiene.sql` after review** / leave.
- **D5–D9 (carried from M21 §8):** D5 App Store Connect analytics report request **yes**; D6
  promotional text **yes**; D7 Sentry city-level geo off — your go-ahead; D8 TestFlight internal group
  **yes** — now worth more: you could try the widget and control on your own phone before submission;
  D9 repo hygiene (deletions are yours) — deleting the empty `metadata/* 2` folders also lets the
  release preflight run without its override.
- **D10 Content widget ("Coming up" / "On this day"):** **not in M22.** It needs an App Group — a new
  entitlement after which SwiftData's default `groupContainer: .automatic` would likely open a
  *different, empty* store in the group container (iCloud users re-download; local-only users would see
  an empty library) — and "On this day" would put your words or sound labels on a locked phone.
  Earliest: M23, a "Coming up" widget with no content (dates only), read from a small file the app
  writes into the group — never the store — after the store location is pinned
  (`groupContainer: .none`) and that pin has shipped.
- **D11 Multi-device last day (B2):** **only after S0 shows a push was sent**, together with D3;
  otherwise M23. (Every device that syncs in the last day would then show two banners — the push has no
  `content-available`, so nothing de-duplicates it in the background.)
- **D12 Standing earned by recording on a new phone (item 3):** **leave**, documented.
- **D13 Onboarding listening answer (item 4):** **leave** — there is no listening page.
- **D14 Where the widget is offered:** **listed under "Other" on CarPlay and for iPhone widgets on Mac**
  (still addable there, just not suggested); say if you want it suggested there, or not offered at all
  (WidgetKit cannot hide it).

---

## 9. Reuse map

| Need | Already exists |
|---|---|
| The one capture door | `CaptureRequests` → `requestCapture()` → `CaptureLaunchRoute` (M20 S5) |
| An intent that opens capture idle on every OS | `OpenCaptureIntent` (both mode declarations, no `#if`) — the pattern the control's intent copies |
| Source-shape guards | `CaptureLaunchTests`, `ProOfferTests`, `SoundprintNeverLeavesTheAppTests` |
| Translated strings | "New capsule" (`Localizable.xcstrings:1782`) |
| Policy tests for release tooling | `scripts/test_asc_policy.py` (CI `unittest discover`) |
| Mutation harness | `scratchpad/mutate.py` pattern (M20/M21 §13) |
| A widget target with the same signing flags | Stride's `StrideWidgetExtension` (reference only; classic groups) |
| Release tooling with guards | `release-preflight.sh`, `build-upload-asc.sh`, `asc.py`, `asc_policy.py` |

---

## 10. Acceptance criteria

- §0 success list holds; both simulator witnesses and the dry archive are recorded in §13 with what was
  tapped and what opened.
- Every new test has a recorded control mutation that made it fail; every gate change has a fixture in
  `scripts/test_gates.py` that made the old gate pass and the new gate fail.
- CI green on the final commit; `MIN_TESTS` ≥ the final count.
- 1.12.0 submitted through the guarded tools; release on Jason's word.

---

## 11. Out of scope / M23

- A content widget (D10): first the `groupContainer: .none` pin with an upgrade test, shipped in a
  release **before** any App Group entitlement; then a dates-only "Coming up" read from an app-written
  file in the group.
- The stale-cancel family — the offline unseal → re-seal orphan and item 6 — with one stamp-keyed
  server cancel (migration + function deploy + app), and B1, after more witnesses, one of them
  multi-device.
- A medium widget, interactive buttons, Live Activities, a "start recording" intent (recording without
  a tap stays out).
- Placing the control on the Lock Screen or Action Button in marketing copy before a device check.
- An iOS 17 runtime for local testing (Jason's call; several GB).
- Carried from M21 §11: `sealedAt`, the orphan sweep, rejection identifier migration, the Swift 6
  re-measure, `CLGeocoder` → MapKit, Xcode 27 on CI.

---

## 12. Review record

### Round 1 — Gemini 4 Argon (high), via `agy --mode plan`, and four review lenses, 2026-11-10

Every finding was checked against the code before the plan changed. Gemini: 10 findings, verdict
CHANGES REQUESTED. Lenses (feasibility; gates; privacy, promises and copy; delivery): 9 + 12 + 11 + 7
findings. Merged where they overlap:

| ID | Sev. | Finding | Check | Change |
|---|---|---|---|---|
| R1-1 (G) | blocker | A membership exception cannot add one file to a target that does not own the folder | **disputed**: the grounding and the gem read it as "included"; no project on this Mac uses the form (Stride uses classic groups) | §4D: the S3 build settles it; fallback `Shared/` folder in both targets; the reader asserts the extension's roots |
| L-F1, L-G1 | blocker | S3's dry archive runs `rm -rf build/Soundpost.xcarchive` — the only copy of 1.11.0 | right (`build-upload-asc.sh:27,92`) | 1.11.0's archive copied to Xcode's Archives (2026-11-10); §4B.7 path overrides |
| L-F2 | major | Sharing `OpenCaptureIntent` puts the shipped door at risk: iOS 27 SDK says `openAppWhenRun` errors if the intent runs in an extension, and iOS 27 may run an intent in any target | right (AppIntents swiftdoc) | §1.11, §4C: `OpenCaptureIntent` stays app-only; the control uses a new `OpenIntent` in the shared file |
| L-F3 | minor | SwiftUI's scene delegate implements `openURLContexts`/`continue` itself; the supplied delegate may never see a URL | right (`nm` of the iOS 18.5 SwiftUI binary) | §4C: `.onOpenURL`, not the scene delegate |
| G R1-2, L-G4 | major | Debug-only: the app-only premise string fails on the extension; an executable count passes without the appex (Sentry is a second Mach-O) | right (`check-debug-only.sh:121-124`; archive contents) | §4B.4: named executables, per-binary premise |
| G R1-3, L-G2, L-P3 | major | Localization pools keys across catalogs; the shared file's strings would be checked against the app catalog only | right (`check-localization.sh:112-114,:217`) | §4B.2 per-target catalogs; §4D catalog holds every compiled key |
| L-G3 | major | Filtering warnings on roots would drop project-file, plist and test warnings | right (`check-warnings.sh:21,38`; logs) | §4B.3 |
| L-G5 | major | "One distinct version" passes when the extension sets none | right (the three parsers) | §4B.5: project-level versions, no overrides |
| L-G6 | major | The override disables the dSYM/SHA checks, so a dry run could not prove `verify_archive` | right (`build-upload-asc.sh:108,131`; preflight refuses today) | §4B.6 separate, never-overridable entry point; D9 note |
| L-G7 | major | A line-regex root parser would drop roots once `exceptions = (…)` appears | right (Xcode's syntax) | §4B.1 brace-matching reader, `test_gates.py` |
| L-P1 | major | iOS 27 sees only the `supportedModes` path; "iOS 18 and later" would ship unseen | right (`supportedModes` iOS 26) | §0, §4D, §8 H2 blocks S5 |
| L-P2 | major | A widget tap leaves the app, which ends a take — "the take continues" cannot be witnessed for widgets | right (`AudioRecorder.swift:208-212`) | §4D witness expectations |
| G R1-4 | major→minor | After standing is granted, labels return a sync late (launch re-syncs before recording standing; remote consent does not record it) | right, and fail-closed | §4E: stated; launch order unchanged |
| L-P5 | minor | `:240` ignores the listening setting too | right | §4E tests both cases + re-issue |
| L-D1/L-D2 (G R1-5) | major | The after-due skip almost never applies, and for `no_tokens`/retry jobs it brings back a late push | right (trace in review) | item 2 left (§4E) |
| L-D3, G R1-6 | major | The re-seal enqueue inside `seal()` pollutes shared defaults, survives a failed save, misses `normalizeSealHours`, and widens item 6 | right | moved to M23 with item 6 (§4E, §11) |
| G R1-7, L-F4, L-G11, L-P8 | major/minor | Census/guard patterns: count calls not declarations, exclude tests, word-bounded tokens; background modes in other plists | right | §4C, §4D |
| G R1-8, L-G10 | minor | `deno check` needs care (`Deno.Kv`, `der`), runs after a network-dependent `deno cache`, and a fatal check revives the moving-target risk | right | §4B.10: warning-level check before `deno cache` |
| G R1-9, L-G9 | minor | Draft items must be fetched with their version; a reopened rejection (`READY_FOR_REVIEW` with a date) must never be reused or cancelled | right | §4B.8 |
| G R1-10, L-P10 | minor | Notes parity skips a missing versioned file; JA/ZH notes missing; blocked words scan only `release_notes.txt` | right | §4B.9, §4F |
| L-F5, L-P11 | minor | `disfavoredLocations` does not hide; Mac location unconsidered | right (swiftdoc) | D14 |
| L-F6, L-P7 | minor | Privacy guard misses the shared file, boot-time APIs, and network symbols SwiftUI re-exports | right | §4B.6 `nm -u`; §4D guard scope |
| L-F7 | minor | `NSExtension` dict, `PRODUCT_NAME`, embed attributes, asset-catalog choice, catalog keys | right | §4D table |
| L-F8 | minor | "Still loads on iOS 17" needs a weak-import check | right | §4B.6 |
| L-F9 | minor | Disk is 17 GB; iOS 27 witness also at risk | right | §8 H2 |
| L-G8 | minor | Requiring `en` everywhere turns `AppShortcuts.xcstrings` red | right | §4B.2 union of non-source languages |
| L-G12 | minor | The dry archive uploads dSYMs and registers an identifier | right | §4B.7, §4D, H3 |
| L-P9 | minor | "Label unchanged" must not read as "label correct" (D7 open) | right | §6 |
| L-D7 | minor | wrong citation for unseal | right | §3 |

Verdict: CHANGES REQUESTED → revised (revision 2, committed `7c86868`).

### Round 2 — Gemini 4 Argon (high), via `agy --mode plan`, 2026-11-10

Two attempts produced nothing (headless mode auto-denied a shell command, then a file read); the
third ran with file reading allowed and shell commands still refused. It confirmed the `OpenIntent`
design against the SDK (`OpenIntent: SystemIntent`, `target: Value` where `AppEnum` refines
`AppValue`, the `ControlWidgetButton` `OpenIntent` overload), that keeping `OpenCaptureIntent`
app-only removes L-F2's risk, the `.onOpenURL` placement, the per-target localization, the draft
policy, and **withdrew its own R1-1** (a membership exception adds a file to a target that does not
own the folder). Verdict CHANGES REQUESTED, with four findings — checked against the files, most of
which **do not describe this repository**:

| ID | Finding | Check | Change |
|---|---|---|---|
| R2-1 | `check-debug-only.sh:111-127` (`SHIPPING_ROOTS`, `glob`, `on_disk != app_files`) rejects the shared file | **wrong**: none of that code exists; the gate reads executables from the project reader (S1, `b4ea025`) | none |
| R2-2 | §4E's `migrateDefaultEnabledIfNeeded` / `notificationsUserChose` migration overwrites opt-outs | **wrong**: no such migration is in the plan or the code; §4E is the lock-screen fix | none |
| R2-3 | `@Parameter` synthesizes no `init(target:)`; the gate does not scan `@Parameter(title:` or `TypeDisplayRepresentation(name:` | **right** | §4C/§4D use `NewCapsuleControlIntent()` with an explicit `init()` (as written in S2); the gate scans both, with a `test_gates.py` case and a control (removing the pattern fails it) |
| R2-4 | preflight reads versions with `grep -m1`; items fetch lacks `fields`; `test_gates.py` missing | (1) **wrong** (it reads `grep … \| sort -u`, which still sees one value; the plan never said it uses the reader); (2) **right** that the plan said `fields` while the code uses `include` (`include` returns the linkage); (3) **wrong** (committed in S1) | §4B.8 text |

Its summary also credited `verify-archive.sh` with checks it does not have (`MinimumOSVersion`, dSYM
UUIDs, `CaptureDoor` symbols). Read with care: a reviewer citing code that is not there is not
evidence. Verdict after checking: the plan stands with R2-3 and the R2-4 wording applied.

---

## 13. Build record

*(one subsection per step: commits, tests and counts, controls, gate fixtures, simulator witnesses,
CI runs, deviations from this plan and why)*

### S1 — gates and tools that see each target

**What changed.**
- `scripts/lib/project_model.py` (new): the project read through `plutil -convert json` — no parser
  of ours at all, so Xcode's field order cannot hide a root. Targets, kinds, executables, roots,
  membership exceptions (excluded for the owning target, added for any other), settings; refuses a
  missing or Swift-less root, a missing added file, an unknown exception class, no app target.
  *Deviation from §4B.1:* the plan said "a brace-matching parser"; `plutil` is Apple's own reader of
  the same format and strictly better.
- `check-localization.sh`: per target, against that target's own catalogs; required languages are
  the union across catalogs; widget/intent constructs scanned (`.configurationDisplayName(`,
  `.description(`, `.displayName(`, `IntentDescription(`, `DisplayRepresentation(title:`,
  `LocalizedStringResource`, and stored or dictionary-literal values typed
  `LocalizedStringResource` / `TypeDisplayRepresentation` / `DisplayRepresentation`).
- `check-warnings.sh`: ours = under `$PROJECT_DIR/` (minus `SourcePackages`, `/DerivedData/`), plus
  path-less lines ending `from project 'Soundpost')`; the macro pairing uses the same root.
- `check-debug-only.sh`: every shipping executable the project names, each with its own premise
  anchor (`Soundpost heard`; the extension's widget kind); a target with no anchor fails.
- Versions: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` moved from the two targets' four
  configurations to the project's two (`xcodebuild -showBuildSettings` resolves 1.11.0 / 23 for both
  targets); `check-store-metadata.py` refuses a target override, a missing project value, an
  `*-Info.plist` with its own version, a version with no `release_notes-<version>.txt`, and scans the
  versioned notes for blocked words. The three existing `sort -u` readers still see one value.
- `scripts/verify-archive.sh` (new), called by `build-upload-asc.sh` after archiving, fatal, not
  covered by the override; `ARCHIVE_PATH`/`EXPORT_PATH` overrides; archive mode with no Sentry token
  uploads no dSYMs. Run on a scratch copy of the live 1.11.0 archive: passes; doctored three ways
  (app dSYM renamed to an extension's, a stray `PlugIns/Stray.appex`, the app executable moved) —
  each refused with its own line.
- `asc.py` / `asc_policy.py`: `READY_FOR_REVIEW` leaves `CANCELABLE` and `BLOCKING`;
  `reusable_draft` (refuses a draft with a `submittedDate` — a reopened rejection — with the
  thread-keeping path, and two drafts); `draft_items_plan` (an unreadable item counts as another
  version); `cmd_submit` finishes a draft or, only when there is none, cancels and creates; items
  are read with `include=appStoreVersion`.
- `apns.ts:132` → `new Uint8Array(opts.payloadBytes)`; CI runs `deno check` on the four import-free
  files before `deno cache`, as a warning. Local Deno 2.7.5: check passes, 18 tests pass. (2.9.8 not
  available here; CI's run is the evidence.)

**Proof.** `scripts/test_gates.py` (new, 30 tests; CI's `unittest discover` now runs 78). Each fixture
tree is built in a temp folder; macOS's own `clang` makes real Mach-O binaries for the binary and
archive fixtures. **Run against each gate's previous version (from `HEAD`), the fault tests fail**:
localization 12 failures (7 tests, subtests counted), warnings 3 of 4, debug-only 5 of 5, store/version
5 of 6 — the tests that still pass there are the "this passes" cases. Run against the new gates: 30/30.
On the real repo: localization passes ("1 target(s), 3 catalog(s), 354 strings"); with
`OpenCaptureIntent`'s title and description changed to uncatalogued text, the new gate names both and
the old gate passed.

**Controls (`scratchpad/mutate_any.py`, cp snapshot → mutate → run → restore → `cmp`):**

| Mutation | Killed by |
|---|---|
| `READY_FOR_REVIEW` back in `CANCELABLE` | `test_export_compliance_may_be_cancelled_but_a_draft_may_not` |
| `reusable_draft` ignores `submittedDate` | `test_a_reopened_rejection_is_never_reused` |
| `draft_items_plan` treats an unreadable item as this version | `test_an_item_whose_version_cannot_be_read_is_not_assumed_to_be_this_one` |
| `cmd_cancel` called before the reuse decision | **survived** the first version of `test_submit_finishes_a_draft_and_creates_only_when_there_is_none`; the test now requires exactly one `cmd_cancel`, inside the create branch → killed |
| the create branch's `cmd_cancel` removed | same test |
| items read without `include` | `test_the_draft_items_are_read_with_their_versions` |
| `draft_items_plan` replaced by `if not held` | `test_submit_finishes_a_draft_and_creates_only_when_there_is_none` |

**Round 2 follow-up (in S2's commit):** the localization gate also scans `@Parameter(title:` and
`TypeDisplayRepresentation(name:` (R2-3), with two `test_gates.py` cases; control: the pattern
removed → `test_widget_and_intent_copy_is_scanned` fails.

### S2 — the shared door

**What changed.** `Soundpost/Services/CaptureDoor.swift` (new; imports only AppIntents and
Foundation; no `#if`): `CaptureRequestHandling`, `CaptureRequests` (moved from `CaptureLaunch.swift`,
now `static weak var coordinator: (any CaptureRequestHandling)?`), `CaptureDoor` (the widget URL
`soundpost://new-capsule`, the exact matcher, `open(_:)`), `CaptureDestination` (one-case `AppEnum`)
and `NewCapsuleControlIntent: OpenIntent` (`isDiscoverable = false`, explicit `openAppWhenRun` and
iOS 26 `supportedModes`, `@Parameter(title: "Capsule")` set by `init()`). Every string reuses an
existing translated key. Type-checked alone as the extension will compile it
(`swiftc -typecheck -application-extension`, iOS 17.0, Swift 5 and 6 modes): no error, no warning.
`CaptureLaunch.swift` keeps the route and the quick action and adds `extension
NotificationCoordinator: CaptureRequestHandling {}`. `SoundpostApp.swift`: `.onOpenURL {
CaptureDoor.open($0) }` on `mainOrOnboarding` inside `production`. `OpenCaptureIntent.swift`: **not
touched** (byte-identical to `HEAD`; its SHA-256 is pinned).

**Tests:** `CaptureDoorTests` (13): the control's intent and the shortcut's intent each set only the
request (the newest-wins rule holds; the route waits during onboarding); the control's intent opens
the app and is hidden from Shortcuts; a request with no hook (the extension's case) is harmless; the
URL table (12 near-misses: trailing slash, path, query, fragment, user, port, other hosts and schemes,
no `//`); `open` sets the request only for the exact URL; censuses over the project's shipping roots
read from the project file with `PropertyListSerialization` (each requires the app's root and >50
files, so an empty scan fails): one `startRecording(` call (the record button), four `showingCapture =
true` sites (all in `ContentView.swift`), one `requestCapture()` call (the hook), no background mode
beyond `remote-notification` in any `*-Info.plist` or build setting; the shared file's imports and
forbidden names; `OpenCaptureIntent.swift`'s hash; the URL handler outside the onboarding switch and
the only one. 736 tests (CI floor 723 → 736).

**Controls** (`scratchpad/mutate.py`, `-only-testing:SoundpostTests/CaptureDoorTests`,
`-collect-test-diagnostics never`; restored and `cmp`-checked: `restored: True` both runs):

| ID | Mutation | Killed by |
|---|---|---|
| D1 | the control's intent does not set the request | `theControlsIntentSetsTheRequestAndNothingElse` |
| D2 | `isDiscoverable = true` | `theControlsIntentOpensTheAppAndStaysOutOfShortcuts` |
| D3 | the matcher accepts a query | `onlyTheWidgetsExactURLOpensCapture`, `openingAURLSetsTheRequestOnlyWhenItIsTheWidgets` |
| D4 | the matcher accepts a path | `onlyTheWidgetsExactURLOpensCapture` |
| D5 | `open` requests capture before matching | `openingAURLSetsTheRequestOnlyWhenItIsTheWidgets` |
| D6 | a second `startRecording(` call site (the scene delegate) | `onlyTheRecordButtonStartsARecording` |
| D7 | a door sets `showingCapture = true` | `captureIsShownOnlyAtItsFourKnownPlaces` |
| D8 | a door calls `requestCapture()` directly | `onlyTheHookAsksForCapture` |
| D9 | `audio` added to `UIBackgroundModes` | `noBundleRunsInTheBackgroundBeyondPushes` |
| D10 | the shared file imports UIKit | `theSharedFileNamesNothingAppOnly` |
| D11 | `OpenCaptureIntent.swift` edited (one space) | `theShortcutsIntentIsUnchanged` |
| D12 | the URL handler moved inside the onboarding switch | `theWidgetsURLReachesTheDoorOutsideOnboarding` |
| D13 | `coordinator!` (a request with no hook crashes) | the test host crashed (0 tests ran) — `withNoHookARequestDoesNothing` is the test that reaches it |
| D14 | the shortcut intent stops setting the request | `theShortcutsIntentStillSetsTheRequest`, `theShortcutsIntentIsUnchanged` |

### S3 — the widget extension

**What changed.** `SoundpostWidget/` (new: `SoundpostWidgets.swift`, `LauncherWidget.swift`,
`NewCapsuleControl.swift`, `Localizable.xcstrings`), `SoundpostWidget-Info.plist` (repo root;
`NSExtension` → WidgetKit, `CFBundleDisplayName` Soundpost, no version keys), and the project file,
hand-edited in its own zero-padded style: appex file reference `D3`, root group `B3`, exception set
`B4` (`Services/CaptureDoor.swift` → the extension), native target `C3` with phases `F7`–`F9`,
configurations `E9`/`EA`/`EB`, the app's "Embed Foundation Extensions" phase `FA` with build file `AD`
(`RemoveHeadersOnCopy`), container proxy `AE`, target dependency `AF`. `plutil -lint` OK;
`objectVersion` 77, `compatibilityVersion` "Xcode 16.0", `preferredProjectObjectVersion` 77 unchanged;
a read-only xcodeproj-gem open lists the three targets, the app's dependency on the extension, the
embed phase (spec 13, the appex, `RemoveHeadersOnCopy`) and the exception set; `xcodebuild
-showBuildSettings` resolves 1.11.0 (23), iOS 17.0, `APPLICATION_EXTENSION_API_ONLY`, `SKIP_INSTALL`
for the extension. The extension's sources type-check together with the shared file at iOS 17.0,
`-application-extension`, Swift 5 and 6 modes: no error, no warning.

**R1-1 settled by the build.** The membership exception adds `CaptureDoor.swift` to the extension:
its debug dylib exports `CaptureDoor.opensCapture`, `newCapsuleURL`; it holds no
`OpenCaptureIntent`, `NotificationCoordinator` or `CaptureView` symbol; the extension's
`Metadata.appintents` lists only `NewCapsuleControlIntent`; the app's lists both
`OpenCaptureIntent` and `NewCapsuleControlIntent`. The `Shared/` fallback was not needed.

**Guards** — `WidgetExtensionTests` (12): the folder's exact files; imports only SwiftUI / WidgetKit /
AppIntents; forbidden names in the extension (capture code, Pro, store, `UserDefaults`, `@AppStorage`,
`URLSession`, `FileManager`, boot time, `OpenCaptureIntent`) and required-reason names in the shared
file; one `widgetURL(CaptureDoor.newCapsuleURL)`, no `Button(intent:)`, no `Link(`; the control
behind `if #available(iOS 18.0, *)` and acting through `NewCapsuleControlIntent()`; both kinds pinned
(and the debug-only gate's anchor equal to the widget kind); the three families, `.never`, a container
background; the extension catalog's keys and that every shared key is translated exactly as the app
translates it; the project builds the extension with one owned folder, exactly one added file, no
package, no entitlement, no version of its own, iOS 17.0, extension-API-only, `SKIP_INSTALL`, its bundle
id and plist, Swift 5, no template concurrency setting; the app embeds it (spec 13) and depends on it;
no `.entitlements` but the app's, and no App Group; the extension's plist is WidgetKit with no version
and no background mode. `SoundprintNeverLeavesTheAppTests` now also reads the extension's three files
and the shared file. The door censuses (S2) read the extension's folder too, via the project. 748 tests
(CI floor 736 → 748). Localization: "2 target(s), 4 catalog(s), 358 strings".

**Controls** (`mutate.py`, `-only-testing` the two suites; `restored: True` on every run):

| ID | Mutation | Killed by |
|---|---|---|
| W1 | the launcher imports UIKit | `itImportsOnlyTheWidgetFrameworks` |
| W2b | the provider reads `UserDefaults` (W2's first version dropped an implicit return and did not compile) | `itNamesNothingItMustNot` |
| W3 | a `Link` instead of the door's `widgetURL` | `theWholeWidgetOpensTheAppThroughTheDoor` |
| W4 | the control offered only from iOS 26 | `theControlIsBehindIOS18AndOpensThroughTheControlIntent` |
| W5 | the widget kind renamed | `theKindsNeverChange` |
| W6 | a family dropped | `theLauncherOffersTheThreeFamiliesAndNoContent` |
| W7 | the extension translates "New capsule" differently | `theExtensionsStringsAreTheApps` |
| W8 | the extension sets `MARKETING_VERSION` | `theProjectBuildsTheExtensionWithNothingExtra` |
| W9 | the extension copied outside `PlugIns` (spec 7) | `theAppEmbedsTheExtension` |
| W10 | "application-groups" appears in the entitlements | `noTargetHasAnAppGroup` |
| W11 | the extension point is not WidgetKit | **the simulator refused to install the app** (`MIPluginKitBundle _validateNSExtension…`) before any test ran — the platform enforces it first |
| W11b | the extension's plist hard-codes `CFBundleVersion` | `theExtensionsInfoPlistIsAWidgetWithNoVersionOfItsOwn` |
| W12 | the launcher's source mentions a soundprint | `noExportSurfaceReadsWhatSoundpostHeard` |
| W13 | a stray file in the extension's folder (by hand; removed after) | `theExtensionHoldsExactlyItsFiles` |

**Seen working — iOS 27 simulator** (`iPhone 17 Pro`, C53F6992-…, under `/tmp/lock-iphone-17-pro`,
Debug build, fresh install, 2026-11-10 15:36–15:40 JST):

1. The widget gallery lists **Soundpost → "New capsule"** with "Opens Soundpost ready to record.
   Nothing records until you tap the record button." and the small preview; added to the Home Screen.
2. **Cold launch, onboarding unfinished:** tap → onboarding (no capture over it) → Skip → capture opens,
   **idle** ("Up to 60 seconds. Tap to start."). The widget's URL reached `.onOpenURL` **with no URL
   scheme registered** — §4C's first option; no fallback needed.
3. **Control case:** a plain launch from SpringBoard (`simctl launch`) shows the gallery, no capture.
4. **Warm launch:** app in the background, tap → capture idle.
5. The control gallery lists **Soundpost → "New capsule"**; added to Control Center. **Cold launch**
   (app terminated) tap → capture idle — the `OpenIntent` ran in the app.
6. **During a take:** recording at 0:02, Control Center pulled down, the control tapped → the take went
   on (0:11, "Recording…"), and stopped at 0:18 into review; discarded. `.alreadyOpen` as designed.
   The microphone prompt appeared only at the first tap of the record button.
7. **The shipped door, with the extension installed:** Spotlight's top hit for "New capsule" is
   Soundpost's App Shortcut, **listed once**; cold launch → capture idle.

**Not seen:** a Lock Screen widget — the simulator did not open Lock Screen customization from an
injected long press, so the accessory families are covered by the shared view code, the gallery and
the guards only; and a widget tap during a take (expected: leaving the app ends the take into review).
**iOS 18.5: not yet** — the Mac had 14 GB free; the global rule forbids booting `Soundpost-iOS18` under
30 GB (§8 H2). S5 waits for it.

**Dry signed archive** (2026-11-10, after `528e931`): screen unlocked, login keychain `no-timeout`;
`ARCHIVE_PATH`/`EXPORT_PATH` in `~/Library/Caches/Soundpost-build/dry-archive/`, `SENTRY_AUTH_TOKEN`
unset, `RELEASE_PREFLIGHT_OVERRIDE=yes` for the preflight only (the empty `metadata/* 2` folders, D9).
`** ARCHIVE SUCCEEDED **`; `verify-archive.sh` on the real binaries: "Soundpost.app 1.11.0 (23), 1
extension(s), each the same version, WidgetKit, no Sentry, no networking or required-reason imports,
later-than-iOS-17 symbols weak; app dSYM present"; dSYM upload skipped; `** EXPORT SUCCEEDED **`
(`app-store-connect`, automatic). The export signed the extension with **"iOS Team Store Provisioning
Profile: com.soundpost.Soundpost.Widgets"** — automatic signing with the ASC API key registered the
extension's identifier and its App Store profile itself (H3: nothing for Jason to do in the portal);
its only entitlement is the team identifier. `build/Soundpost.xcarchive` untouched (still 1.11.0 (23)).

### S4 — the lock-screen copy obeys standing and the listening setting

**What changed.** `NotificationCoordinator.planAndReconcile` takes `reveal` from
`notificationsMayRevealHeardSounds` (= `SoundAnalysisPreferences.mayReveal`) instead of
`isEnabled`, and uses it for the content version and for the digests, now built by the extracted
`static func digests(for:rejections:reveal:)`, which carries a soundprint only when `reveal` is true
and the corrections were readable. The M21 launch order is unchanged.

**Tests:** `LockScreenRevealTests` (4): the digest carries the label only when it may be revealed
(and never on a failed corrections read); the body when hidden equals an unanalysed capsule's, and
differs from the revealed one (so the fixture's label really reaches a body); the rule across all four
listening × standing cases with the content version (`p1` only for on + standing; `p1n` otherwise, so
1.11's bodies are re-issued); a source guard that the coordinator asks the rule in both places and
never reads `isEnabled`. With `NotificationCopyTests` and `LaunchSequenceTests`: 26 green. 752 tests
(CI floor 748 → 752).

**Controls** (`restored: True`):

| ID | Mutation | Killed by |
|---|---|---|
| L1 | the rule reads listening alone | `theRuleIsListeningAndStanding`, `theCoordinatorAsksTheRevealRule` |
| L2 | the digest carries the label whatever `reveal` says | `aHeardSoundReachesTheDigestOnlyWhenItMayBeRevealed`, `theBodyIsTheSameAsAnUnanalysedCapsulesWhenHidden` |
| L3 | the content version ignores `reveal` | `theCoordinatorAsksTheRevealRule` |
| L4 | the sync reads `isEnabled` for `reveal` | `theCoordinatorAsksTheRevealRule` |

