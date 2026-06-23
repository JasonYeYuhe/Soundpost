# Soundpost — Development Plan (post-MVP) · v2

> Status 2026-06-09: **M1–M7 complete** (MVP + pre-submission hardening). 43 tests green, warning-free
> build, real icon, privacy manifest, version 1.0.0. Full loop works (record → card gallery → play →
> seal → resurface); localized EN/JA/ZH-Hans.
>
> **v2 = revised after review by Gemini 3.1 Pro (verdict: minor revisions) and Codex (verdict: major
> revisions).** Both converged; their corrections are folded in below and summarized in §6 (Changelog).
> Grounded in `docs/PROJECT.md`, the M7 audit, and a 14-project reuse survey (§5 Reuse Map — every reuse
> cites a source file).

---

## 0. North star & non-negotiables (unchanged)

- **The card is the dopamine.** Sound-of-a-moment as a glanceable, mood-tinted waveform card.
- **Future-self delivery is a delight, not the identity.** Don't lead with the price-poisoned framing.
- **Offline-first, private, native, zero-account to start.** Nothing leaves the device without explicit action.
- **Honesty over theater.** Seal = honor-system (no offline time-lock on iOS). Delivery = best-effort; we will **not** call anything "guaranteed."
- **i18n EN / JA / ZH-Hans from day one.**
- **Never charge to *receive* a past memory** (the FutureMe revolt). Lapsed Pro never locks an already-created or already-due capsule.

---

## 1. Decisions (D1–D5) — recommendation + reviewer consensus

| # | Decision | Recommendation (both reviewers agree unless noted) |
|---|---|---|
| D1 | Data durability / backup | **CloudKit mirroring** (`NSPersistentCloudKitContainer`) for Apple-only v1.x — *but* the schema must be CloudKit-legal **now** (done in M8) and audio uses **one** strategy (see §3). Revisit Supabase only for Android/web. |
| D2 | Far-future delivery | **Ship v1 honest best-effort** (local 64-cap, built). Add a **cloud-backed** (not "guaranteed") delivery server in M10. Both reviewers: drop "guaranteed". |
| D3 | Observability | **Sentry lands in M8, before the first public release** (Gemini + Codex both moved it earlier). Crash/hang only, PII-scrubbed, no third-party tracking. |
| D4 | Monetization | Launch **free**; later a **one-time or annual** Pro (no monthly — recurring server cost must justify recurring price). Pro sells creation richness + cloud durability. Receiving is always free. |
| D5 | Two design calls | Brand AccentColor + deeper-amber Joyful *foreground* (keep yellow waveform fill). **Do before screenshots.** ⚠️ Still pending Jason's sign-off on the exact colors (proposals in M8). |

---

## 2. Roadmap (milestones)

Each milestone compiles, passes tests, and is committed before the next. Reuse cited as `Project:path`.

### M8 — Ship v1.0: observability + submission  ·  *highest priority*

> **Progress (2026-06-09):** ✅ schema CloudKit-ready · ✅ DEVELOPMENT_TEAM + iPhone-only ·
> ✅ name reserved ("Soundpost: Sound Capsules", app id 6778389097) · ✅ **Sentry** wired (8.58.3,
> Release-gated, PII-stripped; project `soundpost` in org `jason-yeyuhe`) + PrivacyInfo updated ·
> ✅ **Privacy Policy + landing live** on GitHub Pages → privacy
> `https://jasonyeyuhe.github.io/soundpost-site/privacy.html`, support/marketing
> `https://jasonyeyuhe.github.io/soundpost-site/` (repo `JasonYeYuhe/soundpost-site`) ·
> ✅ D5 colors (coral AccentColor + amber Joyful) ·
> ✅ **listing copy EN/JA/ZH** (`metadata/`) + **pushed to ASC** (subtitle, privacy URL, description,
> keywords, support/marketing URL, promo — all 3 locales) ·
> ✅ **build/upload tooling** (`scripts/build-upload-asc.sh` + ExportOptions) ·
> ✅ **device archive + distribution signing** verified · ✅ **signed build UPLOADED to App Store
> Connect** (TestFlight processing) ·
> ✅ **localized App Store names**: ja 「音信」, zh-Hans 「声笺 · 声音胶囊」 (set in ASC) ·
> ✅ **build VALID + attached to the 1.0 version** ·
> ✅ **live audio loop verified on simulator** via a DEBUG `-runAudioSelfTest` harness
> (record → 57KB .m4a → 56-bucket waveform → playback = PASS; silence only because the headless
> sim has no mic input).
> **✅ SUBMITTED TO APP REVIEW (2026-06-10).** Version 1.0 (build 2, new cream-envelope icon) is
> `WAITING_FOR_REVIEW`. All requirements completed: category Lifestyle, age rating 4+, App Privacy
> nutrition label (Crash + Other Diagnostic Data, not-linked/not-tracking, App Functionality)
> published, Free pricing in 175 regions, 6.5" screenshot, App Review contact. Release is **MANUAL**
> — after Apple approves (≤48h, email), Jason releases it manually (nothing goes public until then).
> Post-launch nice-to-haves (not blockers): a real-device pass of the live record + notification
> fire→tap; a fuller/framed screenshot set; the M9+ roadmap (CloudKit durability, server delivery,
> monetization, M12 polish).
>
> *Known non-blocker: Sentry.framework's own dSYM isn't in the archive (its internal frames won't
> symbolicate; the app's own dSYM uploads fine).*

**8a. CloudKit-ready schema (P0, do before 1.0 ships — done in this milestone).**
- ✅ Remove `@Attribute(.unique)` from `Capsule.id`; make every persisted property optional or defaulted; uniqueness at app layer. (`Soundpost/Models/Capsule.swift`.) This makes the *shipped* 1.0 store need **no scalar migration** when CloudKit turns on in M9. Audio-field migration is handled separately in M9 (§3).
- Set `DEVELOPMENT_TEAM = KHMK6Q3L3K`; **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`) — avoids mandatory iPad screenshots + iPad-quality review; aligns with PROJECT.md's "no iPad-tuned UI" cut.

**8b. Observability (Sentry) — before submission (D3).**
- Add a `canImport(Sentry)`-guarded `SentryBootstrap` (compiles without the package; no-op when DSN empty); DSN via `INFOPLIST_KEY_*`; `beforeSend` scrubs the one-line note, audio paths, location. Report the M7 swallowed failures.
  - Reuse: `Stride:Shared/SentryBootstrap.swift`, `cli pulse:.../SentryLogger.swift` (regex scrubbing), `ggc读书:Shared/SentryBootstrap.swift`.
  - **Needs Jason:** create the Soundpost Sentry project (DSN) + add the Sentry SPM package via the **Xcode GUI** (CLI SPM hangs on Sentry's binary xcframework — TokyoHelp's note).
- **PrivacyInfo + ASC privacy label move in lockstep:** add Crash Data + Other Diagnostic Data (linked=false, not tracking, purpose=AppFunctionality). Privacy label becomes "Data collected: Crash/Diagnostics, not linked, not used for tracking."
  - Reuse: `Stride:PrivacyInfo.xcprivacy`, `FlowPilot:Resources/PrivacyInfo.xcprivacy`.

**8c. Submission.**
- ✅ **Bundle id registered** (`com.soundpost.Soundpost`) and **app record created** (2026-06-09).
  Note: the ASC API forbids app *creation* (`'apps' does not allow 'CREATE'`) — done via the ASC
  web UI (Chrome). The bare name "Soundpost" was already reserved by another developer, so the
  **App Store name is "Soundpost: Sound Capsules"** (app id **6778389097**); home-screen name
  stays "Soundpost". ASC API key works for everything *else* (metadata, builds, TestFlight).
  - Reuse: `Tetsuzukit:scripts/asc_api.sh`, `RoastMate:scripts/build-upload-asc.sh` (same KEY_ID/ISSUER/TEAM).
- **Build + upload:** add `scripts/build-upload-asc.sh` (`xcodebuild archive` → `exportArchive`, `-authenticationKeyPath`, `destination=upload`). **No `xcodegen`** — Soundpost has a hand-authored `.xcodeproj`. Reuse `RoastMate:ExportOptions.plist` (app-store-connect, team KHMK6Q3L3K, automatic).
- **Privacy Policy URL (hard ASC requirement)** + support URL: host a static page (free Name.com `.app` / Namecheap `.me` / GitHub Pages). Add an in-app Settings link to it.
- **Listing copy EN/JA/ZH-Hans:** name, subtitle, keywords (carry "audio memory / voice journal / sound capsule"), description, promo, release notes. Reuse `RoastMate:metadata/<lang>/`, `Stride:metadata/<lang>/`.
- **Screenshots: iPhone 6.9"** (current required class — *not* 6.7"). Generate from the simulator with `-seedSampleData`. Reuse `Stride:scripts/screenshots.sh` + `generate_screenshots.swift`.
- **D5 colors before screenshots** (proposals for sign-off): brand AccentColor; Joyful amber foreground.
- **Reviewer notes:** on-device-only, no account, ambient-recording consent, honest gentle seal, sample-data launch arg. Reuse `RoastMate:metadata/review_notes.txt`.
- **On-device manual test (cannot be automated):** live record loop + a short-interval seal → notification fire → tap → open. Required before release.
- **Age rating, content rights, no ATT** (no tracking).
- **Acceptance:** archive validates & uploads; TestFlight build present; metadata/screenshots/privacy-policy complete; Sentry verified (test crash, no PII); submitted (or held at "ready to submit" pending Jason).

### M8.5 — v1.1 "Echo" + onboarding + motion polish  ·  *(Jason's feature batch, 2026-06-10)*

> **SHIPPED TO REVIEW (2026-06-10): 1.1.0 (build 4) is WAITING_FOR_REVIEW.** Per Jason's call,
> the 1.0 submission was withdrawn (DEVELOPER_REJECTED), the version renamed 1.1.0, build 4
> attached (incl. the seal quick-pick i18n fix + echo bell badge), descriptions gained an Echo
> bullet, and 15 branded screenshots (5 × en/ja/zh-Hans, caption-framed) replaced the lone shot.
> Verified end-to-end on simulator (3 locales) before submitting; App Privacy label published.

- **Echo (回响/こだま):** every saved capsule draws a random day **7–30 days out** — "this capsule
  will remind you of today in N days" — shown in the review step, date-editable, removable.
  Implementation: `Capsule.echoAt: Date?` (optional → CloudKit-legal); echoes & seals share the
  nearest-64 notification window (`PlannedNotification.kind`); **sealing supersedes the echo**
  (a hidden capsule must not "remind you of today"); per-kind notification copy
  ("An echo from your past · N days ago, you captured this sound").
- **Onboarding (3 pages):** capture intro → location (with context, "Allow Location Access") →
  echo/notifications ("Enable Reminders"). Permissions asked **with priming context** instead of
  bare at-launch prompts (review-safe); everything skippable, just-in-time asks remain as fallback.
  First-run flag via `@AppStorage` → PrivacyInfo now declares UserDefaults (CA92.1).
- **Motion & haptics:** breathing record button, springy mood chips, play/pause symbol morph,
  gallery insert transition, `.sensoryFeedback` on record/stop/save/chip-select — all gated on
  Reduce Motion where motion-heavy.
- 18 new strings localized EN/JA/ZH-Hans (85 keys, 100%); `EchoTests` suite covers planner/store/
  capture-flow behavior.

### M9 — Durability: stop losing capsules on uninstall (D1)

- **One audio strategy (P0):** migrate the `.m4a` from file-based `AudioStore` to **`@Attribute(.externalStorage) var audioData: Data?`** on `Capsule` (Core Data/CloudKit maps large binaries to CKAsset transparently). **Do not** keep file storage + CloudKit mirroring in parallel (two reconciliation systems). Record to a temp file → read into `audioData` on save; play via `AVAudioPlayer(data:)`. **Lazy-load:** the gallery query must fetch metadata/waveform only, never fault `audioData` until playback (memory).
  - Reuse: `ggc读书:Shared/Models/Book.swift` (`@Attribute(.externalStorage)`).
- **Tested migration** from the shipped 1.0 file-based store → `audioData` (read each file, populate, delete file). The riskiest migration; write it + test before enabling CloudKit. Reuse `FlowPilot:Models/ModelMigration.swift` (VersionedSchema).
- **Enable CloudKit** (`cloudKitDatabase`), container + entitlement; promote schema to production in CloudKit Dashboard. Container init ladder iCloud→local→in-memory. Reuse `RoastMate:Shared/SharedModelContainer.swift`, `timeless:TimelessModelContainer.swift`.
- **Edge cases (Gemini/Codex):** surface `CKError.notAuthenticated` (signed out) + quota; don't present as "broken".
- **Multi-device notifications:** a capsule synced from another device has **no local notification** scheduled here → on CloudKit import, (re)build the 64-nearest local schedule. (Extends the existing planner.)
- **Add `updatedAt: Date?`** now (optional) for future LWW. Reuse `Stride:Shared/Habit.swift`.
- **Honest-copy update:** soften the M7 "no backup — uninstall erases" warning to reflect iCloud backup + its on/off state.
- **Acceptance:** delete+reinstall on a signed-in device restores capsules incl. audio; signed-out/quota handled; migration test green; gallery doesn't load audio blobs.

### M10 — Cloud-backed delivery (the seal upgrade — *not* "guaranteed")

- **Honest framing:** a server durably *enqueues and attempts* delivery; APNs display stays best-effort (silent-push throttling, token churn/expiry, user-disabled notifications). Copy: **"cloud-backed delivery."**
- **Use visible *alert* pushes** (not silent) as the primary far-future fire; "push as a fetch signal, content restored from iCloud (M9)". Launch-time reconciliation as backstop.
- **In-app:** APNs registration + device-token upsert with the user/iCloud identity; **multi-token** registration; **invalid-token cleanup**; relink token on reinstall/new-device. Reuse `TokyoHelp:ios/.../AppDelegate.swift`, `cli pulse:.../PushTokenSync.swift`. APNs key on disk: `~/Documents/secrets/AuthKey_2R9PCC63MF.p8`.
- **Server (Supabase Pro, org Kanousei):** `notification_jobs` queue (`FOR UPDATE SKIP LOCKED`), APNs HTTP/2 sender, dead-letter/retry, cron trigger (timing-safe secret). Reuse `TokyoHelp:supabase/functions/send-notifications/index.ts`, `Kanousei:src/app/api/cron/*`.
- **Privacy/legal (Codex P1.6):** device tokens + jobs are now collected → update PrivacyInfo + ASC label; add server-side token/job deletion when the user deletes a capsule or the app.
- **Solo-dev longevity caveat** stays in honest copy (a server maintained for years is itself a risk).
- **Acceptance:** a seal days out fires via APNs after force-quit/reinstall (manual on-device); invalid tokens pruned; deleting a capsule removes its server job.

### M11 — Monetization (post-PMF, D4)

- **StoreKit 2** Pro, **annual + lifetime** (no monthly). Reuse `Kinen:.../StoreService.swift`, `Stride:.../StoreService.swift`; paywall `Stride`/`ColorArchive`/`Tetsuzukit`.
- **If Pro gates server delivery (M10):** backend entitlement verification + **App Store Server Notifications v2** are part of acceptance (not deferred). Reuse `ColorArchive:server/apple-jws.js`.
- Free tier stays generous; **lapse never locks an already-created or already-due memory.**
- **Acceptance:** purchase/restore/entitlement refresh in StoreKit testing; localized paywall; server-gated features verify server-side.

### M12 — UX & feature polish (pull items forward freely)

Onboarding (`FlowPilot:.../OnboardingView.swift`), haptics (`ggc读书:HapticManager.swift`), milestone review prompt (`ggc读书:ReviewManager.swift`), Settings (language override `Stride:LanguageManager.swift`; privacy/support links; iCloud toggle; storage; export/delete), widget/Live Activity "next to resurface", share extension (`FlowPilot:SharedDataService.swift`), `os.Logger` (`timeless:TimelessLogger.swift`).

### Mx — Engineering hardening (ongoing)

Swift 6 strict concurrency (`Tetsuzukit:project.yml`); grow tests around reinstall re-registration + CloudKit reconciliation (adapt `Stride:StrideTests/SyncReconcileTests.swift`); **avoid Stride's `SyncService` bugs** (C2/C3/C4 in `Stride/STRIDE_V2_REPORT.md`) — prefer CloudKit over hand-rolled sync; keep build warning-free + i18n at 100%.

---

## 3. Architecture: the two hard parts

**Durability ≠ delivery.** M9 (CloudKit) solves *data loss*; M10 (server+APNs) solves *delivery reliability*. They compose: the push is a wake/fetch signal; capsule content is restored from iCloud, never sent through APNs (4KB cap, coalescing).

**Audio = ONE strategy (Codex P0.2).** From M9, audio lives as `@Attribute(.externalStorage) Data?` on the model (→CKAsset), lazy-loaded. We do **not** also sync `.m4a` files via iCloud Drive. v1.0 ships file-based (simplest, already tested); M9 migrates with a tested upgrade path. The file→Data migration is the single riskiest step — own it deliberately.

**Why not Supabase for everything?** It works (Pro is paid) but adds account + RLS-vs-offline friction + server ops. CloudKit = free backup/sync on Apple-only; a *tiny* Edge Function = delivery. Smallest honest surface.

---

## 4. Privacy / legal state by milestone (keep PrivacyInfo + ASC label + policy in lockstep)

| Milestone | New data | PrivacyInfo / ASC label | Other |
|---|---|---|---|
| M8 (v1.0) | none leaves device (mic/location on-device) + **Sentry crash/diagnostics** | Crash + Other Diagnostic Data (linked=false, not tracking) | **Privacy Policy URL** (required), in-app privacy/support links |
| M9 | iCloud storage of capsules | iCloud is the user's own container (not "collected by you"); document in policy | Handle signed-out/quota |
| M10 | **APNs device tokens + server jobs** | add Device ID/Identifiers (functionality, not tracking) | server-side delete on capsule/app deletion |
| M11 | purchase/entitlement | add Purchases (not linked to identity if anonymous) | App Store Server Notifications |

Also from launch: **in-app delete** (exists) + **data export** (bulk export-your-data, M12 — distinct from M11's Pro per-capsule *share* export), age rating, content-rights, **no ATT** (no tracking).

---

## 5. Reuse Map (appendix)

| Theme | Best source(s) | Use for |
|---|---|---|
| Submission scripts | `Tetsuzukit:scripts/asc_api.sh`, `RoastMate:scripts/build-upload-asc.sh`, `Stride:scripts/build-appstore.sh` | ASC JWT; archive→export→upload |
| ExportOptions | `RoastMate:ExportOptions.plist` | app-store-connect, automatic, team KHMK6Q3L3K |
| Metadata layout | `RoastMate:metadata/`, `Stride:metadata/` | per-language listing `.txt` |
| Screenshots | `Stride:scripts/screenshots.sh` + `generate_screenshots.swift` | sized/validated (target 6.9") |
| Reviewer notes / checklist | `RoastMate:metadata/review_notes.txt`, `cli pulse:docs/ASC_SUBMISSION_v1.9.4.md` | App Review |
| Sentry (iOS) | `Stride:Shared/SentryBootstrap.swift`, `cli pulse:SentryLogger.swift`, `ggc读书:SentryBootstrap.swift` | privacy-first crash/hang |
| PrivacyInfo (diagnostics) | `Stride:PrivacyInfo.xcprivacy`, `FlowPilot:Resources/PrivacyInfo.xcprivacy` | Crash/Diagnostics categories |
| MetricKit | `Kinen:Sources/Core/DiagnosticsService.swift` | zero-network diagnostics (optional) |
| CloudKit container | `RoastMate:Shared/SharedModelContainer.swift`, `timeless:TimelessModelContainer.swift` | iCloud→local→memory ladder |
| externalStorage blobs | `ggc读书:Shared/Models/Book.swift` | audio as Data→CKAsset |
| Migration plan | `FlowPilot:Models/ModelMigration.swift` | VersionedSchema |
| Sync timestamps | `Stride:Shared/Habit.swift` | `updatedAt` + `touch()` |
| APNs in-app | `TokyoHelp:ios/.../AppDelegate.swift`, `cli pulse:.../PushTokenSync.swift` | token register/upsert/cleanup |
| Server push | `TokyoHelp:supabase/functions/send-notifications/index.ts`, `Kanousei:src/app/api/cron/*` | job queue + APNs + cron |
| StoreKit 2 | `Kinen:.../StoreService.swift`, `Stride:.../StoreService.swift` | products/purchase/restore |
| Paywall UI | `Stride`/`ColorArchive`/`Tetsuzukit` PaywallView | tiered paywall |
| Receipt verify (server) | `ColorArchive:server/apple-jws.js` | Apple JWS + ASSN v2 |
| Onboarding | `FlowPilot:Views/Onboarding/OnboardingView.swift` | first-run |
| Haptics | `ggc读书:GGCReader/HapticManager.swift` | record/seal feedback |
| Review prompt | `ggc读书:GGCReader/ReviewManager.swift` | milestone rating |
| Language override | `Stride:.../LanguageManager.swift` | in-app language |
| Logger | `timeless:TimelessLogger.swift` | os.Logger domains |
| Sync tests | `Stride:StrideTests/SyncReconcileTests.swift` | in-memory reconciliation |

**Not reusable:** Cortex, landmark, Islanders (templates/macOS). RoastMate "voice" = transcription, not recording. Take only cross-platform pieces from Tetsuzukit/Kanousei/cli pulse (macOS/web in part).

---

## 6. Changelog — what the Gemini + Codex review changed (v1 → v2)

1. **Schema CloudKit-readiness pulled into M8** (was implicit in M10). Removing `@Attribute(.unique)` + defaulting all props *before* 1.0 ships avoids a painful post-launch migration. **(P0, both.)**
2. **Audio durability committed to ONE strategy** (`externalStorage Data` → CKAsset), explicit file→Data migration in M9; no parallel iCloud-Drive file sync. **(P0, Codex.)**
3. **"Guaranteed" delivery removed everywhere** → "cloud-backed"; alert (not silent) pushes, token churn/cleanup/relink, launch reconciliation. **(P0, both.)**
4. **Sentry moved into M8** (before first public release), with PrivacyInfo + ASC label in lockstep. **(P1, both.)**
5. **iPhone-only** (`TARGETED_DEVICE_FAMILY=1`) to avoid mandatory iPad screenshots; screenshot target corrected **6.7"→6.9"**. **(P1, Codex.)**
6. **Privacy/legal matrix added** (§4): privacy-policy URL as a hard M8 requirement; in-app privacy/support links; server token/job deletion before M10. **(P1, Codex.)**
7. **StoreKit:** annual/lifetime only (no monthly); server entitlement verification + App Store Server Notifications in-scope if Pro gates server delivery; lapse never locks existing/due memories. **(P2, Codex.)**
8. **M8 "not fully unblocked"** acknowledged: on-device record/notification test remains a manual gate. **(P1, Codex.)**

*Next action: finish M8 — I'm applying 8a now (schema/team/iPhone-only done), reserving the name via ASC API, then drafting listing copy + build/upload tooling. Sentry full wiring + on-device test + screenshots need Jason (DSN + Xcode SPM add + a physical device).*
