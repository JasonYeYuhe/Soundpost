# Soundpost M14 — The Pro micro-levers (custom mood colour + custom echo window)

> Development plan for the phase after M13. Status feeding in (2026-07-30):
> **M13 SHIPPED** to the codebase and **1.4.0 (build 9) is `WAITING_FOR_REVIEW`**.
> Standing bars: **246 tests / 0 warnings / i18n EN·JA·ZH-Hans 100% / zero new
> third-party deps** (beyond Sentry). CI live & green (macos-26 / Xcode 26.5); dSYM
> upload live. Live App Store version **1.3.0**. Deployment target **iOS 17.0**.
> The M10 delivery backend is live (**do not touch**).
>
> Scope comes straight from `docs/M13-DEVPLAN.md` §11, which designated these two
> levers as M14 and — importantly — already recorded *why they are not the same
> kind of feature*.

---

## 0. Goal & success statement

M11 sold Pro on **creation richness**; M13 added the strongest artefact (the
shareable video). M14 adds the two small, personal levers that were deliberately
cut from M13 for being unrelated to video: letting a Pro user **choose what a mood
looks like**, and **how far out a surprise echo lands**.

Both are small. The milestone's actual difficulty is not the features — it is that
**they have opposite lapse semantics**, and getting either backwards ships a
violation of the app's cardinal rule.

**Done when:** a Pro user can recolour any mood and pick their own echo window; a
lapsed user keeps seeing their colours but silently returns to the default echo
window for *new* captures; nothing already made changes; build warning-free, all
tests green, i18n 100%, zero new deps, CI green.

## 1. Non-negotiables (carried from PROJECT.md / M9–M13)

1. **Never charge to receive a memory.** Both levers are Pro *creation* choices.
   Reveal, browse/search, notifications, export-your-data, playback and the M13
   video's *existing* output stay free.
2. **Honest limits.** A custom colour is a preference, not a per-capsule field —
   say so. Changing a mood's colour restyles every capsule of that mood, including
   old ones; that is the intended behaviour of a palette, and the UI must not imply
   otherwise.
3. **Calm, no dark patterns.** No nagging, no "your colours will be lost" scare
   copy on lapse (they will not be lost). **Reset-to-default is always available to
   everyone**, so no user can ever be stranded with a palette they cannot undo —
   the same reason `.classic` is always available (M11 §4D(iii)).
4. **Privacy-first.** No new data collected, no backend, no new Required-Reason
   API. Both preferences are app-owned `UserDefaults` (already declared CA92.1).
   No PrivacyInfo change, no nutrition-label change.
5. **Offline-first, no backend churn.** M10 backend and M11 gating untouched.
6. **No regression / standing bars:** warning-free on Xcode 26; ALL tests green;
   i18n EN·JA·ZH-Hans 100% **every step**; zero new third-party deps; CI green;
   crashes symbolicated. Each step compiles + passes tests + is **committed**,
   ending each commit with:
   `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## 2. Scope

**IN:** (a) a pure **`MoodPalette`** + its store, with every tint read routed
through it — including **M13's video renderer**; (b) a **Pro-gated echo window**
read at capture-start; (c) Settings UI for both, gated, with reset; (d) paywall
lines; (e) i18n every step; (f) tests that pin **both** lapse behaviours.

**OUT (→ M15?):** per-capsule colour overrides (a CloudKit schema change — §4A);
custom themes beyond the M11 pack; more video formats/templates; the WidgetKit
widget; the Swift 6 flip; promo/win-back codes.

### 2A. Headline

**Two levers, opposite lapse rules, proven by test.** Committed core = S1–S4.

## 3. Current state (grounded — cite before you change)

| Concern | Where | Note for M14 |
|---|---|---|
| Mood tint | `Models/Mood.swift` `tint` (a `switch` returning a fixed `Color`) | Becomes `defaultTint`; a palette resolves the effective colour. **11 read sites** across ContentView, CaptureView, ResurfaceView, CapsuleCard, ShareCardView, CapsuleDetailView, VideoExporter. |
| The lapse-safe precedent | `Models/Theme.swift` + `@AppStorage("cardTheme")` in views | The exact pattern to copy: a **pure** resolver over a stored raw value that **never** consults `isPro`, observed by views via `@AppStorage`. |
| Echo seeding | `Capture/CaptureViewModel.swift` `randomEchoDate(from:in:)`, `in range: ClosedRange<Int> = 7...30`; seeded at `seedEchoIfNeeded()` / capture | The range must come from the **gate at capture-start**, not from a stored preference read blindly. |
| Gate | `Models/ProGate.swift` (`maxRecordingDuration`, `canExport`, `availableThemes`) | Add one lever of **each** kind, so the type itself documents the asymmetry. |
| Video tint | `Services/VideoExporter.swift` `VideoTint.resolved(from:)` | M13 §11 flagged this: the video must render the **stored** tint, never `isPro`. Resolved on the main actor and passed as a value. |
| Settings | `Views/SettingsView.swift` (`proSection`) | Host both controls here. |

## 4. Architecture / design decisions

**A. Palette is global, not per-capsule.** A `UserDefaults`-backed mood→colour map,
exactly like `Theme`. Per-capsule colour would need a new `Capsule` field and so a
CloudKit schema change, for a feature nobody asked to vary per memory. Global also
makes lapse-safety trivial: rendering reads the stored map, so a lapse changes
nothing on screen.

**B. `MoodPalette` is pure; the store is separate.** `MoodPalette(stored:)` parses a
compact string; `tint(for:)` answers from it, falling back to `Mood.defaultTint`.
No `isPro`, no I/O, fully unit-testable. Views observe one
`@AppStorage("moodPalette")` string so a change repaints immediately — the same
mechanism `cardTheme` uses.

**C. Colour encoding: a hex string per mood, in one compact value.** `mood=RRGGBB`
pairs joined by `;`. Human-readable in the defaults plist, trivially forwards-
compatible (unknown moods are ignored), and needs no `Codable` migration. Colours
are stored **resolved sRGB**, so — like `ShareCardView`'s deterministic inks — an
exported card or video looks the same regardless of the device appearance at
render time.

**D. The asymmetry, stated once and encoded in `ProGate`:**

| Lever | Kind | Lapse behaviour | Read at |
|---|---|---|---|
| Custom mood colour | a **rendered preference** | **Lapse-safe.** Keeps rendering forever; only *editing* is gated. | render time, via the palette (never `isPro`) |
| Custom echo window | a **seed for new captures** | **NOT lapse-safe.** A lapsed user's *new* captures fall back to 7–30; already-set `echoAt` values are untouched. | **capture-start**, via `ProGate` |

Getting this backwards in either direction is the bug M14 must not ship, so each
direction gets its own test.

**E. Echo-window shape.** A closed day range with a sane floor/ceiling (1…365) so a
Pro user cannot create an echo that fires today (defeating the surprise) or one so
far out it is really a seal. Free/lapsed default stays exactly `7...30`.

**F. Reset is free.** "Use the default colour" is available to everyone, always
(§1.3). It is not a Pro action — it only ever *removes* a stored override.

## 5. Work breakdown (sequenced; each step compiles + passes tests + commits)

**S1 — `MoodPalette` + every tint read routed through it.** Pure type + store;
`Mood.defaultTint`; the 11 sites; `VideoTint` resolved from the palette on the main
actor. *Verify:* unit tests for resolution, unknown/garbage input, round-trip, and
**lapse-safety** (a stored colour renders identically with `ProGate(isPro: false)`);
the M13 video tests still pass; warning-free.

**S2 — The Pro echo window, gated at capture-start.** `ProGate.echoWindow`;
`randomEchoDate` takes the range from the gate. *Verify:* a Pro window is honoured
for a new capture; a **lapsed** user's new capture falls back to 7–30; an existing
capsule's `echoAt` is never recomputed; the range is clamped.

**S3 — Settings UI + paywall + i18n.** Both controls in `proSection`, gated, with
reset. Paywall lines. All new strings EN·JA·ZH-Hans in the same commit.
*Verify:* free sees the gate and no broken control; Pro sees both; i18n 100%.

**S4 — Verify, release prep, upload.** Full suite + gates; simulator UI pass;
version bump + three-language notes; archive + upload with dSYMs; create the ASC
version record. **Do NOT submit while 1.4.0 is in review** (§8).

> Drop order if tight: S2's window becomes a fixed **two-option** choice (default
> 7–30 / "sooner" 3–10) rather than a free range. **Never drop:** S1's lapse-safety
> tests, S2's fall-back-when-lapsed test, S3's reset affordance.

## 6. Privacy / legal delta

**None.** No new data, no backend, no new IAP (both ride the existing Pro
entitlement), no new Required-Reason API — both preferences are the app's own
`UserDefaults`, already declared **CA92.1**. PrivacyInfo and the ASC nutrition
label are unchanged. Re-verify at S4.

## 7. Risks & mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| Lapse semantics implemented backwards | **High** | §4D's table; a dedicated test per direction; `ProGate` holds one lever of each kind so the contrast is visible in one file. |
| A tint read site missed → inconsistent colours | Med | Enumerate all 11 in §3; make `Mood.tint` unavailable (rename to `defaultTint`) so the compiler finds every site. |
| The video renders the wrong (or stale) colour | Med | `VideoTint` resolved from the palette on the main actor and frozen into the render input (M13 §4F); M13's frame tests still assert card/waveform contrast. |
| A user picks an unreadable colour | Med | Contrast floor when resolving; reset always available (§4F). Waveform/ink legibility is the same concern M7 fixed for `.joyful`. |
| Scope creep into per-capsule colours | Low | §4A: global only; per-capsule is a CloudKit schema change and is OUT. |
| Submitting M14 cancels M13's in-flight review | **High** | §8: hard stop before `asc.py submit` until 1.4.0 leaves review. |

## 8. Human-in-the-loop checklist (needs Jason)

- [ ] **Do not submit M14 while 1.4.0 is `WAITING_FOR_REVIEW`.** ASC allows one
  version in the review pipeline, and `asc.py submit` calls `cmd_cancel()`, which
  would **cancel M13's submission** to free the slot. S4 stops at "build uploaded +
  version record prepared"; the submit waits for 1.4.0 to clear.
- [ ] **Release 1.4.0** once approved (`releaseType: MANUAL` — approval does not
  publish).
- [ ] **M13's leftover device check:** `-runVideoSelfTest` on a real device for the
  render-time / file-size numbers that close M13 §8's duration-cap item.
- [ ] Confirm the echo-window bounds (§4E) if 1…365 days feels wrong.
- [ ] Deployment target **stays iOS 17**.
