# Soundpost M11 — Monetization: a gentle, never-charge-to-receive Pro

> Development plan for the phase after M10. Status feeding in (2026-06-22): **M10
> (Cloud-backed delivery) SHIPPED** — 1.3.0 (build 7) is in App Store review
> (WAITING_FOR_REVIEW, Manual release); the Supabase delivery backend is live
> (co-located in the `cli-pulse` project); 116 Swift + 18 Deno tests green,
> warning-free, i18n EN/JA/ZH-Hans 100%, zero new third-party iOS deps. The live
> App Store version is **1.1.0**; **1.2.0 (M9 iCloud durability) was folded into
> 1.3.0**, so 1.3.0 carries M9 durability + M10 delivery.
>
> This plan refines DEVPLAN.md §M11 + §D4 into implementation-ready steps. **Draft
> for review** (Gemini 3.1 Pro + a Claude adversarial pass); fold findings before
> kickoff.

---

## 0. Goal & success statement

Soundpost is **free** and stays generous. M11 adds an **optional Pro** unlock that
sells **creation richness** — never the right to *receive* or *keep* a memory.
StoreKit 2, **lifetime + annual (no monthly)**. Pro is a delight on top of a
complete free app, not a gate in front of one.

**The one decision that shapes everything (§2A):** Pro does **NOT** gate
cloud-backed delivery, sealing, resurfacing, playback, or any already-created
capsule. M10 delivery shipped **free** in 1.3.0; retroactively paywalling it would
be exactly the FutureMe mistake this product was built to avoid. So **no backend
entitlement check, no App Store Server Notifications, no server-side gating** —
monetization is **100% on-device** (StoreKit `Transaction.currentEntitlements`).
This is a deliberate, large scope reduction vs. DEVPLAN's conditional "if Pro
gates server delivery…".

**Done when:** a user can buy Soundpost Pro (lifetime or annual) and restore it;
Pro unlocks the agreed creation features (export/share, longer clips, theme pack);
the **free tier is fully functional and unchanged** (capture, cards, gallery,
playback, seal, echo, iCloud backup, **cloud-backed delivery**); a **lapsed annual
never locks** an already-created capsule, an already-exported file, or any
resurfacing; a localized (EN/JA/ZH-Hans) honest paywall; build warning-free, all
tests green, i18n 100%, **zero new third-party deps** (StoreKit is first-party).

**Posture (read this).** §D4 frames monetization as *post-PMF*, and Soundpost is
pre-broad-launch (1.1.0 live; 1.3.0 in review). This milestone **builds the
monetization scaffold** so it's ready, but recommends a **conservative rollout**:
generous free tier, a single non-nagging paywall surfaced only at the moment a Pro
feature is tapped, and the option to keep prices/visibility modest until there's
traction. Building it now is right; aggressive monetizing is not. If Jason would
rather do **M12 (UX polish: Settings, widgets, broader/video export, language
override)** first, the export work here (S4) is the main shared piece and can be
pulled forward into M12 instead.

**Ship-dormant option (resolves the pre-PMF tension concretely).** The whole
scaffold can land + ship while monetization stays **off**: the binary contains
`StoreService`/`ProGate`/`ProPaywallView`, but with **no ASC products created and
the Paid Applications Agreement unsigned**, `Product.products(for:)` returns empty,
the paywall is unreachable, and **nothing is for sale**. Flipping it on later = the
§8 human steps only — **no new build required** for the products to appear. So
merging M11 doesn't commit to a launch date.

## 1. Non-negotiables (carried from PROJECT.md / DEVPLAN.md / M10)

1. **Never charge to receive a past memory.** No paywall on seal, resurface,
   notification delivery (local *or* cloud), playback, or viewing. (The FutureMe
   revolt; PROJECT.md Monetization decision.)
2. **Lapse is harmless.** A lapsed annual (or any non-Pro state) **never** locks
   an already-created capsule, its audio (even a >60s clip recorded while Pro), an
   already-exported file, or any due/scheduled resurfacing. `isPro=false` only
   gates *starting a new* Pro-gated action.
3. **Offline-first, no backend.** Entitlements resolve on-device via StoreKit 2.
   No server call gates anything; M10's delivery backend is untouched.
4. **No monthly.** Lifetime (non-consumable) + annual (auto-renewable). Lifetime is
   the honest anchor for a "keep forever" product; the **annual is a lower-entry
   on-ramp to the *identical* Pro feature set** — both simply flip the same `isPro`
   flag (§4B/§4C), confer no different entitlement, and (since delivery is free) the
   annual carries no ongoing server cost — it's "support Soundpost + get everything
   Pro, cancel anytime." The paywall copy must say this plainly (§4E). (§D4.)
5. **Honesty over theater.** The paywall says plainly what Pro adds and that
   existing/received memories are never locked. No fake scarcity, no dark patterns,
   no interruptive nags.
6. **No regression:** free experience, tests, i18n EN/JA/ZH-Hans 100%, warning-free
   build, zero new third-party deps (StoreKit + AVFoundation are first-party).

## 2. Scope

**IN:** a StoreKit-2 `StoreService` (load/purchase/restore/entitlements/listener);
a pure `ProGate` mapping entitlement → feature flags; a localized `ProPaywallView`
+ a minimal Pro/Settings entry point (restore + Manage Subscription); a
`Soundpost.storekit` config for local testing; wiring the **agreed Pro features**
(§2B) with paywall triggers; the **export/share** feature (the headline Pro value);
privacy lockstep (evaluate a Purchases declaration); tests + a StoreKit-testing
manual pass.

**OUT (later / explicitly not now):** any **server-side entitlement check / ASSN
v2** (we don't gate delivery — §2A); monthly plans; a full Settings screen,
widgets, Live Activities, in-app language override (**M12**); promo/offer codes,
win-back offers (optional follow-up); Android.

### 2A. THE decision — what Pro gates (and what it must not)

| Capability | Free | Pro |
|---|---|---|
| Capture, mood, place, one-line note, waveform card | ✅ | ✅ |
| Gallery, playback, seal, unseal, echo | ✅ | ✅ |
| iCloud backup/sync (M9) | ✅ | ✅ |
| **Cloud-backed far-future delivery (M10)** | ✅ | ✅ (never gated) |
| Recording length | ≤ 60s | up to 5 min |
| **Export / share** a capsule (card image + audio) | — | ✅ |
| Card **theme/style** pack (beyond the per-mood tint) | base | ✅ |
| _(candidates, pick in S1)_ extra moods / custom mood; custom echo window | — | ? |

Receiving, keeping, and delivering memories are **always free**. Pro sells
*making* and *sharing* them more richly.

### 2B. Pro feature set — recommend a tight v1

Lead with the most compelling + clearly-"creation" + growth-positive set; defer the
rest. **v1 Pro = (a) Export/Share, (b) Longer clips, (c) a Theme pack.** Finalize in
S1; keep it small enough to ship well.

**Conversion hypothesis (be explicit):** **export/share is the anchor** (emotional
payoff + an organic-growth loop — people share their cards); longer clips and the
theme pack are sweeteners. Export stays **Pro-gated** and is NOT freed in M12
(M12's export work is *broader/video* export only — §11). If at rollout this set
doesn't feel compelling enough, that's a product call for Jason (more moods, custom
mood color, custom echo window are the next levers — PROJECT.md), not a plan blocker.

- **(a) Export / share** — the headline. Render a dedicated **share-card view as an
  image** (see §4G — not necessarily a pixel-copy of `CapsuleCard`) + share the
  **audio clip** via the system share sheet. Offered only for **visible** capsules
  (captured / resurfaced / opened / unsealed), never a sealed-not-due locked one.
  (An animated-waveform **video** export is a stretch/M12.)
- **(b) Longer clips** — free 60s → Pro up to 5 min. **NOT trivial** — three
  concrete code realities the implementer must handle (detailed in §4C/§4D + S3):
  (1) `AudioRecorder.maxDuration` is a `let` baked at init → make it settable and
  drive it from `ProGate` at record-start; (2) there is **no "record longer"
  gesture** — the recorder hard-stops at the cap, so the upsell must be an explicit
  affordance, not "tap past 60s" (§4D); (3) `WaveformExtractor` reads the whole file
  into one PCM buffer — a 5-min clip is tens of MB of float RAM on the main actor →
  bound its peak memory (stream in a fixed read buffer). Also: re-localize the
  hardcoded "Up to 60 seconds" capture hint; verify the 56-bucket waveform still
  reads well at 5 min; mind storage (~0.5 MB/min).
- **(c) Theme pack** — a few alternate card styles / accent palettes layered over
  the per-mood tint. **Data model:** a **global app-appearance preference**
  (UserDefaults; a `Theme` enum surfaced via `ProGate.availableThemes`, applied at
  render time in `CapsuleCard`) — **not** a per-capsule field (avoids a CloudKit
  schema change + a clash with the per-mood tint). Lapse-safe: the currently-applied
  theme keeps rendering; only *switching to* a locked theme needs Pro (§4D).

## 3. Current state (grounded — cite before you change)

| Concern | Where | Note for M11 |
|---|---|---|
| Recording cap | `Capture/CaptureViewModel.swift` (`maxDuration: 60`), `Audio/AudioRecorder.swift` (`maxDuration` is a `let`) | "Longer clips" is **not** one knob: make `maxDuration` settable, have the VM read `ProGate` at record-start, add an upsell affordance (no past-60s gesture), bound `WaveformExtractor` RAM, re-localize the "60s" hint (§4D/S3). |
| Capsule detail (export entry) | `Views/CapsuleDetailView.swift` (waveform + playback + delete/seal) | Add an Export/Share button here, paywall-gated. |
| Card rendering | `Views/CapsuleCard.swift`, `Views/WaveformView.swift` (SwiftUI `Canvas`) | Reuse for image export via `ImageRenderer`. |
| Audio file | `Capsule.audioData` (externalStorage) + `Audio/AudioStore.swift` | Export writes a temp `.m4a` from `audioData` for the share sheet. |
| App entry / DI | `SoundpostApp.swift` (`@State` services in env: notifications, syncMonitor, registrar, sealDelivery) | Add `StoreService` to the environment the same way. |
| Settings surface | **none** (gallery `storageFooter` is the only chrome) | M11 adds a minimal Pro entry + restore; full Settings is M12. |
| i18n | `Localizable.xcstrings` (107 keys, EN/JA/ZH-Hans 100%) | All paywall/Pro strings localized. |
| Privacy | `PrivacyInfo.xcprivacy` (Crash/Diag + M10 Device ID/User ID/Other Data) | Evaluate a "Purchases" entry (§6). |
| No StoreKit yet | — | First StoreKit code in the app; add a `.storekit` config for testing. |

## 4. Architecture decisions

**A. On-device only (the §2A consequence).** `isPro` is derived solely from
`Transaction.currentEntitlements`. No network, no receipt server, no ASSN. This is
correct *because* nothing server-side is gated. If a future milestone ever gates a
server feature behind Pro, ASSN v2 + server validation come back — not now.

**B. `StoreService` (StoreKit 2), reuse Kinen's production-tested pattern**
(`Kinen:Sources/Features/Settings/StoreService.swift`, itself from Stride):
`@Observable @MainActor`; `Product.products(for:)` with exponential-backoff retry;
`purchase()` → verify (`VerificationResult`) → `finish()` → refresh; `restore` via
`AppStore.sync()`; `refreshPurchasedProducts()` over `Transaction.currentEntitlements`;
a detached `Transaction.updates` listener (catches renewals, Ask-to-Buy approvals,
refunds, Family Sharing). Drop Kinen's `.monthly` case. Products:
- `com.soundpost.Soundpost.pro.lifetime` — non-consumable.
- `com.soundpost.Soundpost.pro.annual` — auto-renewable, in subscription group
  "Soundpost Pro".
`isPro = !purchasedProductIDs.isEmpty`.

**C. `ProGate` — a pure, testable entitlement→features seam.** A tiny value type
that turns `isPro: Bool` into concrete limits — `maxRecordingDuration`,
`canExport`, `availableThemes`. Views read the gate, never `StoreService` directly,
so (1) the gating rules are unit-testable without StoreKit, and (2) there's one
place to audit "what Pro changes." `ProGate(isPro:)` → free: `maxRecordingDuration
= 60`, `canExport = false`, `themes = [.classic]`; Pro: `300`, `true`, all themes.

**D. Lapse-safety is structural, not a check.** Gates only ever guard *initiating*
a Pro action: (i) **recording length** — read `ProGate.maxRecordingDuration` at
record-start (requires making `AudioRecorder.maxDuration` settable — it's a `let`
today — and having `CaptureView`/`CaptureViewModel` read the gate; the VM is built
with a hardcoded default, so wire the gate in). There is **no "record past 60s"
gesture** (the recorder hard-stops at the cap), so the longer-clip upsell is an
explicit **affordance** on the capture screen / at the 60s auto-stop ("Record up to
5 min with Pro"), not a "tap past 60s" trigger. (ii) **export** — show the button /
present the paywall. (iii) **themes** — only *choosing* a locked theme needs Pro.
Nothing re-reads `isPro` to *revoke* stored content: a capsule's audio plays
regardless of length; an applied theme keeps rendering (render reads the stored/
preference value, never `isPro`); an exported file is the user's; a sealed capsule
resurfaces regardless. **Test** that a capsule created while Pro is fully usable
when `isPro=false`, **including after a reinstall + the entitlement not yet
restored** (acceptance §10.3).

**E. Paywall — one honest surface, triggered in context.** `ProPaywallView` (reuse
`Kinen:ProPaywallView` / `Stride` / `ColorArchive` / `Tetsuzukit`): lists Pro perks;
shows lifetime + annual with localized `Product.displayName` + `displayPrice`;
Subscribe/Buy + **Restore Purchases**. **Required subscription disclosure (App
Review 3.1.2):** for the **annual**, the paywall itself (not a linked page) must
show — *before* the buy action — the **title, the period length + price-per-period,
that it auto-renews, and that it can be cancelled in Settings**; plus links to
**Terms of Use (EULA)** and **Privacy**. **Terms = Apple's Standard EULA**
(`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`) — no EULA page
to author — and **Privacy = the existing `privacy.html`**; both links confirmed to
open. State plainly that the annual + lifetime unlock the *same* features (lifetime
= pay once; annual = same features yearly, cancel anytime) and that existing/
received memories are never locked. **Load/error states are already handled by the
reused Kinen paywall** (loading / load-failed-with-localized-retry / disabled while
loading) — keep that; during the products-load window treat `isPro` as its last
known value and never flash a false Pro/locked state. Presented in context (export,
the longer-clip affordance, a locked theme) + the §4F entry; never interrupts
capture/seal/resurface.

**F. Minimal Pro entry point (full Settings = M12) — committed placement.** A single
toolbar item in `ContentView`'s existing `.topBarTrailing` toolbar (a gear or
`person.crop.circle`, beside the "New capsule" **+**) opens a lightweight sheet:
Pro status, the paywall, **Restore Purchases**, **Manage Subscription**
(`Environment(\.openURL)` + `StoreKit` `showManageSubscriptions` / the App Store
manage URL), and the Terms (Apple EULA) + Privacy links. (Restore must be
discoverable — a paid-app App Review requirement.) Leave the gallery `storageFooter`
focused on honest durability copy. M12 grows this into a full Settings screen.

**G. Export pipeline (S4 — the meatiest new code).** `CapsuleExporter`:
- **Card image**: render a **dedicated share-card SwiftUI view** (composed from the
  same waveform + mood/place/note pieces — *not* a guaranteed pixel-copy of the
  list `CapsuleCard`) via `ImageRenderer` → PNG at ~@3x. No deps. (Acceptance is a
  *faithful, legible* share card, not pixel-equality with the on-screen card.)
- **Audio**: write `capsule.audioData` to a temp `.m4a`.
- Present `ShareLink` / `UIActivityViewController` with both items. (Animated-
  waveform **video** via AVFoundation is a deliberate stretch goal / M12.)
- **Only for visible capsules** (captured / resurfaced / opened / unsealed) — never
  a sealed-not-due (locked) capsule; the `CapsuleDetailView` `lockedView` hosts no
  export affordance, so this is structurally enforced. The card shows only what the
  user already sees (no hidden fields); the export is the user's own data leaving by
  their explicit action.

## 5. Work breakdown (sequenced; each step compiles + commits)

**S1 — StoreService + ProGate + .storekit + unit tests (no UI).** Port Kinen's
`StoreService` (drop monthly); define the two product IDs; add `Soundpost.storekit`
with lifetime + annual for local testing; add `ProGate` (pure). Put `StoreService`
in the app environment. *Verify (unit):* `ProGate` free vs Pro maps the right
limits; lapse-safety invariant (a "Pro-made" capsule stays usable when `isPro=false`);
products load from the `.storekit` file in a manual run. Compiles, warning-free.

**S2 — Paywall + Pro/Settings entry + restore.** `ProPaywallView` (localized,
honest copy, lifetime+annual, restore, manage-subscription, auto-renew + Terms/
Privacy disclosures); a minimal Pro entry point. *Verify:* paywall renders in 3
locales; purchase/restore drive `isPro` in StoreKit testing; "Manage Subscription"
opens; no nag paths.

**S3 — Wire the gates (lapse-safe).** (a) **Longer clips:** make
`AudioRecorder.maxDuration` settable; have `CaptureView`/`CaptureViewModel` read
`ProGate.maxRecordingDuration` at record-start; add an explicit **"Record up to 5
min with Pro"** affordance (capture screen and/or the 60s auto-stop in review) →
paywall — there is no past-60s gesture; re-localize the hardcoded "Up to 60
seconds" hint to reflect the active cap (EN/JA/ZH-Hans); **bound `WaveformExtractor`
peak memory** (stream the file in a fixed read buffer rather than one full-file PCM
buffer). (b) **Themes:** locked theme → paywall (applied theme keeps rendering).
(c) **Export entry point** in `CapsuleDetailView` (S4). Each Pro tap → the single
paywall. *Verify:* free caps at 60s, Pro at 5 min; a >60s clip recorded while Pro
**still plays after a simulated lapse**; a 5-min extract doesn't spike memory; the
hint copy localizes; locked features present the paywall, never a dead end.

**S4 — Export / share (the headline Pro feature).** `CapsuleExporter`: a dedicated
share-card view → `ImageRenderer` PNG + audio `.m4a`; a `ShareLink` from
`CapsuleDetailView` (visible capsules only), gated. *Verify:* the exported card is
faithful + legible (not necessarily pixel-equal to the list card); audio plays in
other apps; share sheet works; no content beyond the card leaves; a sealed-not-due
capsule offers no export; free users hit the paywall.

**S5 — Privacy / legal lockstep + copy.** Evaluate the **Purchases** declaration:
StoreKit purchases are processed by Apple and read on-device (`currentEntitlements`)
— we run **no server** and store no purchase data ourselves, so this likely adds
**no newly-"collected" data**; confirm against Apple's guidance and, if needed, add
`NSPrivacyCollectedDataTypePurchases` (App Functionality, not linked, not tracking)
+ the ASC label, in lockstep. Finalize honest paywall + Pro copy (EN/JA/ZH-Hans);
confirm no new Required-Reason API. Privacy-policy page: add a short "Purchases"
note only if anything is actually collected. **Analytics decision (make it
explicit):** ship with **no conversion/paywall tracking SDK** — consistent with the
no-analytics/no-tracking stance (only Sentry crash today). If a conversion signal is
ever wanted, the only acceptable form is a **local-only coarse counter** that never
leaves the device; **default = none** for v1.

**S6 — Tests + StoreKit-testing manual pass + on-device.** Unit: `ProGate` mapping,
lapse-safety, exporter (image/audio produced, content-bounded). StoreKit testing
(.storekit): buy lifetime, buy annual, **restore**, **lapse/expire an annual**
(StoreKit test can force expiry) → verify nothing locks, **refund** → `isPro` drops
but content stays, **Family Sharing** (if enabled on the non-consumable),
**Ask-to-Buy pending**. Manual on-device once ASC products exist (§8). Record here.

## 6. Privacy / legal delta

Likely **none** beyond a possible "Purchases" entry: no server, no purchase data
stored by us, entitlements read on-device. **Decide in S5**, and if Purchases is
declared, move PrivacyInfo + ASC label + (a one-line) policy note **in lockstep**
(the M10 discipline). No new Required-Reason API. No ATT / tracking. The §D4 matrix
anticipated "add Purchases (not linked to identity if anonymous)" — treat that as
the cap, not a floor.

## 7. Risks & mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| **Retroactively paywalling a free feature** (revolt) | High | §2A: delivery/seal/resurface/playback **stay free forever**; Pro is additive creation richness only. |
| **Lapse locks a memory** (the cardinal sin) | High | §4D structural lapse-safety: gates guard only *new* Pro actions; never revoke stored content. Explicit test. |
| **Selling blocked by missing Paid Apps agreement** | High | §8 human step — sign the Paid Applications Agreement + banking/tax **before** ASC products can exist or IAP can be reviewed. |
| **StoreKit is hard to unit-test** | Med | Test the pure `ProGate` + exporter; use the `.storekit` config + StoreKit testing for purchase/restore/lapse/refund flows. |
| **Monetizing pre-PMF / nagging** | Med | Conservative posture (§0): one in-context paywall, no nags, generous free tier; Jason controls price + when to push. |
| **Long-clip memory / regressions** | Med | A 5-min clip is tens of MB of float PCM — **stream `WaveformExtractor` in a bounded buffer off the main actor**; cap at 5 min; verify the 56-bucket waveform + card still read; storage ~0.5 MB/min. |
| **Subscription-disclosure / IAP review rejection** | Med | §4E: annual paywall shows title + period + price-per-period + auto-renew + cancel inline before buy; Terms→Apple EULA + Privacy links; discoverable Restore; per-product + group localized metadata + screenshot (§8). |
| **Export leaks unintended content** | Med | Export only the share card (what the user already sees) + the audio; no hidden fields; never offered for a locked capsule. |
| **Family Sharing / refund edge cases** | Low/Med | `Transaction.updates` listener handles revocation/refund; test both; `isPro` recomputes from `currentEntitlements`. |

## 8. Human-in-the-loop checklist (needs Jason / ASC)

- [ ] **Sign the Paid Applications Agreement** + complete **banking & tax** in ASC
  (the app is currently free; this is a hard prerequisite for selling IAP).
- [ ] Create the **subscription group** "Soundpost Pro" + the **annual**
  auto-renewable product `com.soundpost.Soundpost.pro.annual`; set price (modest;
  consider an intro/launch price later).
- [ ] Create the **non-consumable** `com.soundpost.Soundpost.pro.lifetime`; set
  price. Decide **Family Sharing** on the lifetime (recommended on; low cost).
- [ ] Localized **display name + description for BOTH products** (lifetime +
  annual) in EN/JA/ZH-Hans; the **subscription group's own localized display name**
  (EN/JA/ZH-Hans — a separate ASC field that blocks review if missing); a review
  note; and a **paywall screenshot** attached to the IAP review (the common
  rejection causes).
- [ ] Decide final **prices** (annual + lifetime) and whether to gate visibility
  until launch (per the §0 ship-dormant option, products can stay uncreated and the
  shipped build simply shows no paywall).
- [ ] Confirm the **Purchases** privacy decision (S5) and, if declared, update the
  ASC nutrition label + policy in lockstep.
- [ ] StoreKit-testing manual pass is automatable locally; the **App-Store IAP
  review** ships with the next build.

## 9. Reuse map

| Need | Source |
|---|---|
| StoreKit 2 service (load/purchase/restore/entitlements/listener) | `Kinen:Sources/Features/Settings/StoreService.swift` (production-tested, from Stride); `Stride:Sources/Services/StoreService.swift` |
| StoreService tests / shape | `Kinen:Tests/StoreServiceTests.swift` |
| Paywall UI | `Kinen:Sources/Views/Screens/ProPaywallView.swift`, `ColorArchive:ios/.../Views/Pro/ProPaywallView.swift`, `Tetsuzukit:Sources/App/PaywallView.swift` |
| Entitlement state shape | `Tetsuzukit:Sources/Services/EntitlementState.swift` |
| Card → image | SwiftUI `ImageRenderer` over the existing `CapsuleCard`/`WaveformView` (in-repo) |
| ASC product/version tooling | in-repo `scripts/asc.py`, `scripts/build-upload-asc.sh` |

> **Not reusing:** `ColorArchive:server/apple-jws.js` / App Store Server
> Notifications — only relevant *if* Pro gated a server feature, which §2A
> declines. Keep it out unless a later milestone gates server delivery.

## 10. Acceptance criteria

1. Buy **lifetime** and **annual** in StoreKit testing; **Restore** works; the
   `Transaction.updates` listener reflects renewals/refunds/Family-Sharing.
2. **Free tier unchanged + complete:** capture, cards, gallery, playback, seal,
   echo, iCloud backup, **cloud-backed delivery** — none gated.
3. **Lapse/refund never locks** an already-created capsule (incl. a >60s clip + an
   applied non-base theme), an exported file, or any resurfacing — **including after
   a delete+reinstall with the entitlement not yet restored** (the capsule plays,
   renders, and resurfaces with `isPro=false`) (tested).
4. Pro unlocks the agreed v1 set: export/share, longer clips (≤5 min), theme pack;
   each gated tap presents the one honest, localized paywall (EN/JA/ZH-Hans).
5. Export produces a faithful card image + playable audio; no content beyond the
   card leaves the device except by the user's explicit share.
6. Privacy lockstep resolved (Purchases declared only if actually collected); no
   new Required-Reason API; no tracking/ATT.
7. Warning-free; all tests green; i18n EN/JA/ZH-Hans 100%; **zero new third-party
   deps**.
8. No server-side change; M10 delivery untouched and still free.
9. **Accessibility (M7 bar):** the paywall + Pro entry are VoiceOver-labeled (Buy/
   Subscribe, Restore, Manage Subscription, dismiss) and Dynamic Type up to the
   accessibility sizes doesn't clip the price / disclosure text.

## 11. Out of scope / next

**M12 = UX & feature polish** (full Settings incl. language override + iCloud/
delivery controls, widgets / "next to resurface" Live Activity, review prompt).
**Export boundary (two different "exports"):** the Pro-gated **single-capsule
*share* export** (card image + audio) ships **here in M11 §S4**. The "export" in
`DEVPLAN.md` §M12 / §4 is a *different* feature — **bulk data-portability
export-your-data** (a privacy affordance), which stays in M12. (DEVPLAN line 182 now
notes this distinction; keep them separate.) M12 also covers *broader/video* share
export (animated-waveform video, multi-capsule). Promo/offer codes +
win-back offers are an optional M11 follow-up. Keep M11 to: a generous free app + a
gentle, additive, never-charge-to-receive Pro.
