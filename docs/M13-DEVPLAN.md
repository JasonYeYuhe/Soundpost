# Soundpost M13 — The shareable waveform video (Pro creation richness)

> ## Status: **S0–S4 IMPLEMENTED** (2026-07-30)
>
> The committed core is complete. **246 tests / 0 warnings / i18n EN·JA·ZH-Hans 100%**,
> zero new third-party deps (AVFoundation + AVKit are first-party), deployment target
> still **iOS 17.0**. M10's backend and M11's Pro gating untouched; no ASC product
> work and no submission (video rides the existing Pro entitlement).
>
> | Step | Commit | Tests |
> |---|---|---|
> | S0 — render proof (spike, since deleted) | `5474c02` | 201 |
> | S1 — composition core + still card | `53b8aeb` | 227 |
> | S2 — the playback-position reveal | `4dd805c` | 228 |
> | S3 — gate before the menu + Photos string | `8620604` | 242 |
> | S4 — progress, cancel, preflight, hardening | `2e30883` | 246 |
> | follow-up — no-partial-file gap, privacy record | `67d8a53` | 246 |
>
> Findings from each step are recorded in the boxes inside §5. Two bugs were found
> and fixed along the way that predate M13: an M12 test that deleted the app's whole
> temporary directory, and `ShareCardView` rendering near-black at the bottom (which
> made "Made with Soundpost" unreadable in **M11's image share** too).
>
> **Still human-gated** (neither blocks the code, both want a person):
> 1. the **S2 device smoke test** — `-runVideoSelfTest` on a real device, to judge
>    visual sync/legibility and to get the device's render time + file size (which
>    closes §8's duration-cap item);
> 2. the **Pro-side UI walkthrough** (menu → video → progress → cancel → share sheet)
>    — needs an entitlement, so run it with **Edit Scheme → Options → StoreKit
>    Configuration → `Soundpost.storekit`**. The free side, the sealed-not-due locked
>    view, and the Pro *menu rendering* were all verified live on the simulator.
>
> ---
>
> Development plan for the phase after M12. Status feeding in (2026-06-28):
> **M12 SHIPPED** (S1–S8). Standing bars: **200 tests / 0 warnings / i18n
> EN·JA·ZH-Hans 100% / zero new third-party deps** (beyond Sentry). **CI live &
> green** (github.com/JasonYeYuhe/Soundpost, **macos-26 / Xcode 26.5**); **dSYM
> upload live** (Sentry `jason-yeyuhe/soundpost`). Live App Store version **1.1.0**;
> **1.3.0 (build 7)** in App Review; **1.4.0 (build 8)** uploaded/VALID. Deployment
> target **iOS 17.0**. The M10 delivery backend is live (**do not touch**).
>
> **Hardened by review (2026-06-28):** a Codex pass + a 4-lens Claude audit
> (iOS/AVFoundation, product/ethics, scope/risk, privacy). Their P0/P1 findings are
> folded in below — most importantly, **the original Core-Animation-burn-in design
> was wrong** (no video track, wrong initializer, and the API is deprecated on iOS
> 26), so the primary path is now **`AVAssetWriter`**. *(Gemini review was requested
> but the Gemini CLI is tier-ineligible on this machine — see §12.)*

---

## 0. Goal & success statement

M11 shipped a static **card + audio** share. M13 ships the **waveform video** — a
short, self-contained `.mp4` that plays the capsule's sound while its waveform
lights up left-to-right in time, on the branded Soundpost card, ready to drop into
iMessage, a feed, or (v1 format permitting) Stories/Reels. It is the strongest
deferred monetization lever — a Pro **creation** richness (additive + lapse-safe) —
and the most shareable artifact the app can make.

It is also the **riskiest** engineering in the app (net-new AVFoundation
encoding: audio/video sync, render time, memory, file size, codec availability). So
the plan is deliberately conservative and **spikes the risk first (S0)**: prove a
real, non-black, audio-synced `.mp4` exports on the CI simulator **before** building
any geometry, UI, or tests on top.

**Done when:** a Pro user can export a capsule as a `.mp4` — the branded card with
its waveform revealing in sync with the audio — and share it via the system sheet;
gated additively (lapse-safe, never charges to *receive*); export runs off the main
actor with progress + cancel and clean temp lifecycle; build **warning-free** on
Xcode 26, all tests green (incl. a CI-safe structural video test + a device smoke
test), i18n EN·JA·ZH-Hans 100%, **zero new third-party deps** (AVFoundation is
first-party), **CI green**, crashes symbolicated.

## 1. Non-negotiables (carried from PROJECT.md / M9–M12)

1. **Never charge to receive a memory.** Video export is a Pro **creation** richness
   (like the M11 card share): additive, **lapse-safe** — an already-shared video is
   the user's; the gate caps only the *start* of a *new* export. The reveal,
   browse/search, notifications, export-your-data, seal/resurface, and playback stay
   **free** — with regression tests (Codex #8) proving they stay free.
2. **Honest limits.** The video shows only what the user already sees (no hidden
   fields; M11 §7). A **sealed-not-due** capsule structurally cannot be exported — the
   locked detail view hosts no export affordance. Soundpost keeps a video only in a
   temp dir until the share sheet finishes; only the copy the user saves/shares is
   durable (so "yours forever" = the user's copy, not an app-retained file).
3. **Calm, no dark patterns.** A gentle left→right playback-position reveal, not
   melodrama. The tasteful "Made with Soundpost" mark stays; a paid "remove watermark"
   lever is **ruled OUT** (§11) — it would double-charge to de-brand already-paid
   output.
4. **Privacy-first.** No tracking (Sentry crash only). No new data collected. The
   video leaves only by the user's explicit share. **Two separate axes** (do not
   conflate — Codex/workflow): (a) *Photos "Save Video"* from the share sheet may need
   the **NSPhotoLibraryAddUsageDescription** runtime purpose string (verify §4G); (b)
   *Required-Reason APIs* — the size preflight must stay **arithmetic-only** (no
   free-disk-space query) unless we add `NSPrivacyAccessedAPICategoryDiskSpace` to
   PrivacyInfo in the same commit. Neither changes the nutrition label.
5. **Offline-first, no backend churn.** 100% on-device AVFoundation. M10 backend and
   M11 Pro gating untouched.
6. **No regression / standing bars:** warning-free build **on Xcode 26** (no
   deprecated-API warnings — a hard constraint that rules out several AVFoundation
   paths, §4A); ALL tests green; i18n EN·JA·ZH-Hans 100% **every step** (the
   localization gate reds CI on any untranslated key); zero new third-party deps; CI
   green (macos-26); crashes symbolicated. Each step (S0→S4) compiles + passes tests +
   is **committed**, ending each commit with:
   `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## 2. Scope

**IN:** (a) a headless **`VideoExporter`** that renders a capsule to a branded
`.mp4` (waveform revealing in sync with the audio); (b) the **Pro gate** + **share
UI** (offer "Share as video" beside M11's image+audio share, gated *before* any
menu); (c) **progress + cancel**, clean **temp lifecycle**, and an **arithmetic size
preflight**; (d) a **CI-safe structural test** + a **device smoke test**; (e) i18n
every step; (f) hardening (memory bound, error surfacing, os.Logger, VoiceOver,
Photos purpose string if required).

**OUT (deferred → §11):** multiple aspect ratios / templates; a "remove watermark"
lever (**ruled out**); music/voiceover; batch video export; the WidgetKit widget;
the Swift 6 flip; promo/win-back codes; **the Pro micro-levers** (custom mood color,
custom echo window) — the review showed they are unrelated to video and the echo
window's lapse model is wrong, so both **move to M14** (§11), leaving M13 tightly
the video.

### 2A. Headline + themes

**Headline: one shareable video, proven before it's built.** One format, one gentle
reveal, correct + memory-bounded. **Committed core = S0–S4** (no splittable tail —
M13 is deliberately narrow).

- **S0 — de-risk:** a throwaway spike that exports a real, non-black, audio-synced
  `.mp4` on the CI sim and *chooses the render path* against exit criteria.
- **S1–S2 — the video:** the pipeline + still card → the animated reveal.
- **S3–S4 — ship it:** the gate + share UI → progress/cancel/preflight/hardening.

## 3. Current state (grounded — cite before you change)

| Concern | Where | Note for M13 |
|---|---|---|
| Static share | `Services/CapsuleExporter.swift` (card image via `ImageRenderer` + audio temp `.m4a` → `SharePayload` → `ShareSheet`); `Views/ShareCardView.swift` (a 360-pt scheme-independent card **that already contains a decorative `WaveformView`**, and an **unbounded** note `Text`) | Reuse the *audio helper*; render a **video-specific card** with `showsWaveform: false` + **fixed line limits** (else two waveforms + cropped long/localized notes — Codex #10, workflow #14). |
| Waveform | `Views/WaveformView.swift` (SwiftUI `Canvas`; `progress` 0…1 brightens played bars) | Extract the bar math into a pure **`WaveformGeometry`** used by the video renderer *and* (optionally) the view, so on-screen and in-video can't drift. A `Canvas` can't be a `CALayer`, so the video path draws bars via **Core Graphics**. |
| Gating | `Models/ProGate.swift` (`canExport`); `Views/CapsuleDetailView.swift` `exportTapped` (free → paywall directly) | Reuse `canExport`. **Gate before any menu** (free users keep the direct button→paywall path; only Pro users see image/video options — Codex #8, workflow #11). |
| Audio source | `Models/Capsule.swift` `audioData` (m4a) + `durationSeconds` (a stored `Double`, **not** the true track duration); `CapsuleExporter.audioFileURL` (blob → temp `.m4a`, **date-only shared filename → collision risk**) | Read the audio via a **unique** temp file; make the **loaded audio-track duration authoritative** for the composition range, frame count, reveal, and tests — never `durationSeconds` (Codex #3, workflow #5). |
| Temp/share lifecycle | `CapsuleExporter` temp files; `ShareSheet` (no completion callback) | Own a **unique export dir** from S1; retain the `.mp4` until `UIActivityViewController.completionWithItemsHandler`, then clean; clean on failure/cancel + scavenge stale dirs on launch (Codex #9). |
| Memory/off-main discipline | M12 `Services/CapsuleBulkExporter.swift` | The off-main + temp-file model to mirror; but `ImageRenderer`/CALayer are `@MainActor` and non-Sendable (§4F). |
| Gate + paywall | `Views/ProPaywallView.swift` (feature list + `context:`) | Add a "Share a video" feature line + a video `context:`. |
| Release-ops | M12 `scripts/build-upload-asc.sh` + `.github/workflows/ci.yml` (macos-26, green) | Standing bars are CI-enforced on every push — keep green. |

## 4. Architecture / design decisions

**A. Render path — `AVAssetWriter` primary (S0 confirms).** The original
Core-Animation-burn-in design is **rejected** (Codex #1/#2, workflow #1):
- `AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer:)` post-processes
  *existing* decoded video frames; an **audio-only** composition has none, so it
  exports audio-only / black — the failure mode as the *default*, not an edge case.
- `AVMutableVideoComposition` + mutable instruction classes, `exportAsynchronously`,
  polling `.progress`, `cancelExport()`, `outputURL/outputFileType` are **deprecated
  on the iOS 26 SDK** → deprecation **warnings** that break the warning-free bar.

**Primary path:** **`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`** for
the video track, muxed with the audio read via **`AVAssetReader`** over the source
`.m4a`. It is **iOS-17-compatible, uses no deprecated APIs (warning-free), gives
deterministic frames (testable), explicit H.264/bitrate control, a bounded pixel-
buffer pool (memory-bounded), and frame-count progress + `cancelWriting()`.** Each
frame = the **still card image drawn once**, blitted into the pixel buffer, plus the
**waveform reveal** for that frame's playback position drawn via Core Graphics
(`WaveformGeometry`). Only the reveal region is recomputed per frame, so a 5-min
clip's ~9 000 frames are cheap blits, not full re-renders. Coordinate space is an
explicit top-left `CGContext` (no `CALayer` y-flip surprise — workflow #4).
*If S0's spike shows the CoreAnimationTool `additionalLayer:asTrackID:` synthetic-
track path (with the **non-deprecated** `AVVideoComposition` async config API) is
materially simpler AND renders non-black on the sim, it may be adopted — but the
default and the plan below assume `AVAssetWriter`.*

**B. One waveform geometry, playback-position reveal.** Extract a pure
**`WaveformGeometry`** (bar rects from samples + a target size: centered,
`barSpacing`, `minBarHeight`, rounded caps — the exact `WaveformView` math) and unit-
test it. The reveal is a **playback-position** sweep (bars left of the playhead are
full color, right are dimmed — matching `WaveformView.progress`), keyed to
`playbackFraction = t / audioTrackDuration`. Name it honestly: this is *playback-
position* sync, **not** amplitude/transient sync (Codex #3).

**C. The video card.** Add `showsWaveform: Bool = true` to `ShareCardView`; the video
renders it with `showsWaveform: false` (the single animated waveform lives in its own
region) and **explicit `lineLimit`** on the note so long/localized content never
crops in the fixed canvas. Render it once via `ImageRenderer` (on `@MainActor`) at
the video scale.

**D. Format — vertical 1080×1920 (v1, overridable).** §0's ROI rests on
Stories/Reels, which are 9:16; a square clip letterboxes there (workflow #6). v1 =
**vertical 1080×1920 / 30 fps / H.264 / AAC** (iMessage + feeds tolerate vertical).
Square/other ratios are OUT (§11). *Overridable in §8.*

**E. Gate + share UI.** Reuse `ProGate.canExport`, **gated before any menu**: a free
user's export tap goes **straight to the paywall** (unchanged, no tease); a Pro user
gets a small menu — **"Share as image"** (existing) / **"Share as video"** (new).
Fold eligibility into a **testable action policy** (`content-visible now` + `valid
audio present` + `Pro at export start`), captured once at start and **never
re-checked mid-render** (Codex #8). New copy localized EN·JA·ZH-Hans.

**F. Off-main boundary.** Build the card image (`ImageRenderer`) and any `@MainActor`
pieces on the main actor, **freeze** them, and hand only value types / the finished
image to the background `VideoExporter`; the writer renders on its own queue.
Document the non-Sendable hand-off so the Swift 6 flip (§11) accounts for it (workflow
#8).

**G. Progress, cancel, temp, preflight (from S1, not deferred).** Progress = frames-
written / total (determinate). Cancel = cancel the owning `Task` + `writer.cancelWriting()`.
**Temp lifecycle from S1:** a unique export dir per run; retain the `.mp4` until the
share sheet's `completionWithItemsHandler`, then delete; delete on failure/cancel;
scavenge stale export dirs on launch (Codex #9). **Preflight = arithmetic only:**
estimate output bytes from a **video-bitrate constant** for the chosen preset (NOT
the `CapsuleBulkExporter` 8 KB/s *audio* figure — workflow #15/Codex #11) × duration;
warn before a long export. **No free-disk-space query** (it is a Required-Reason API,
§1.4) unless declared.

**H. Photos "Save Video".** Before S3, **verify on a real iOS-17 device** whether the
share sheet's "Save Video" requires `NSPhotoLibraryAddUsageDescription`. If yes, add
`INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` **and** a matching
`InfoPlist.xcstrings` entry translated EN·JA·ZH-Hans (else the localization gate reds
CI) in that step (workflow #7).

## 5. Work breakdown (sequenced; each step compiles + passes tests + commits)

**S0 — Render-proof spike + path decision *(do first; de-risk before building)*.**
A throwaway spike (or a `#if DEBUG` self-test, like `AudioSelfTest`) that, on the
**macos-26 CI simulator**, muxes a seeded/still frame + the capsule audio into a
`.mp4` via `AVAssetWriter`, and asserts: an `AVAsset` with one **H.264** video + one
audio track, **non-black** first frame (decode + inspect pixels), duration parity
with the **loaded audio track** (± one frame). Confirm H.264 encodes on the sim
(Codex #6); if not, record the fallback (device-only render + a sim-skipped test).
*Exit criteria:* choose `AVAssetWriter` (default) vs the CoreAnimationTool
synthetic-track path, and record why. *Verify:* the spike's structural assertions
pass in CI; findings written into this doc. **Delete the throwaway before S1** (keep
only what graduates into `VideoExporter`).

> ### S0 findings (2026-07-29) — **PASSED, `AVAssetWriter` confirmed**
>
> `SoundpostTests/S0VideoRenderProofSpikeTests.swift` (throwaway; deleted at S1).
> 201 tests green / 0 warnings / i18n 100%.
>
> **Verdict: keep `AVAssetWriter` as the primary path — no override.** It worked
> first try on the sim; there is no reason to revisit the CoreAnimationTool
> synthetic-track alternative (§11 keeps it documented only).
>
> **1. The simulator *can* do it.** On macos-26 / Xcode 26.6, iPhone 17 sim:
> H.264 **High** profile (`AVVideoProfileLevelH264HighAutoLevel`) encodes at
> **1080×1920 @ 30 fps**, and AAC **passthrough** (`outputSettings: nil` +
> `sourceFormatHint`) muxes into `.mp4`. No sim-skip / device-only fallback is
> needed (§7's contingency is unused).
>
> **2. The frames are real, not black.** First-frame mean luminance **0.242**
> (bar: > 0.05); last frame **0.247** > first, so per-frame drawing genuinely
> changes over time. This is the assertion a purely structural test cannot make.
>
> **3. Sync tolerances — two, not one.** The *video* track lands within **one
> frame (33.3 ms)** of the loaded audio-track duration, as specified. The muxed
> *audio* track needs its own, looser tolerance (**< 100 ms**): passthrough
> carries the source's own packet timing, so container priming/rounding puts it a
> few ms off, and one frame is too tight a bar for it. Both are asserted
> separately rather than folding audio into the frame-accurate claim.
>
> **4. P0 discovered by the spike — the pump must interleave.** Feeding one
> writer input to exhaustion before the other **deadlocks**:
> `isReadyForMoreMediaData` goes false on whichever input runs ahead and is only
> cleared by the *other* input's data. The working shape — a single-threaded loop
> that services whichever input is ready and sleeps only when neither is — is
> what graduates into `VideoExporter`, and it is cancellable and memory-bounded
> by construction. (A two-task/`requestMediaDataWhenReady` design was rejected as
> more moving parts for no gain.)
>
> **5. Orientation idiom confirmed.** An explicit top-left / y-down `CGContext`
> (`translateBy(y: height)` + `scaleBy(y: -1)`) plus a **local** re-flip around
> each `CGContext.draw(image:in:)` — the `UIImage.draw(in:)` idiom. Visual
> upright-ness remains a **device** check (S2), as planned.
>
> **6. Measurements** (iPhone 17 sim, *software* encoder, still card — a device's
> hardware encoder will be materially faster):
>
> | Clip | Frames | Render | ×realtime | Output | Bytes/s |
> |---|---|---|---|---|---|
> | 1 s | 30 | 1.13 s | 1.13× | 113 KB | 113 KB/s |
> | 10 s | 300 | 4.25 s | 0.42× | 775 KB | 78 KB/s |
>
> Target average bitrate is 4 Mbps; actual at 10 s is **≈ 620 kbps** — near-static
> content encodes far under target, and per-second cost *falls* with length as the
> first keyframe amortizes. Extrapolated 5-minute (Pro-max) clip: **≈ 23 MB, ≈ 2
> min on the sim**. **On this evidence no duration cap is needed** for the 5-min
> Pro maximum (§8) — confirm against the device measurement at S2 before closing
> that item. §4G's arithmetic preflight constant is deliberately *not* fixed here:
> it will be set from the S2-era measurement, once the real per-frame reveal (which
> raises the bitrate above this still-card figure) is in.
>
> **7. Pre-existing bug found and fixed** (`SoundpostTests/CapsuleBulkExporterTests.swift`):
> two tests cleaned up with `removeItem(at: folder.deletingLastPathComponent())`,
> but `tempFolder()` returns a *direct child* of the app's temporary directory — so
> the cleanup recursively deleted the whole of `tmp/`. Latent since M12 and
> invisible while every test was `@MainActor` + synchronous (nothing else held a
> temp file at that instant); the S0 spike is the first test to hold temp files
> across an `await`, and its source `.m4a` was deleted mid-render. Fixed to remove
> the bundle folder itself. **Lesson carried into S1:** never delete a parent
> directory, and give the video export its own uniquely-named dir.

**S1 — The composition core + still card (headless, testable).** `VideoExporter`
(off-main): unique temp `.m4a` (audio) → `AVAssetWriter` video (still video card,
**no reveal yet**) + audio mux → `.mp4`, using the **loaded audio-track duration**.
Extract + unit-test `WaveformGeometry`; add `ShareCardView.showsWaveform`; own the
**unique-dir temp lifecycle** now. *Verify (CI-safe, structural):* a real ~1-s clip
exports an `AVAsset` with exactly one **H.264** video + one audio track, 1080×1920
dims, duration parity with the loaded audio track (± one frame); geometry unit
tests; **await `asset.load(.tracks)/.load(.duration)`** in tests (no deprecated sync
accessors); warning-free.

**S2 — The reveal animation.** Draw the per-frame waveform reveal (played brightens,
optional thin playhead) keyed to `t / audioTrackDuration`. *Verify:* a **device
smoke test** (a real capsule exports; card upright + legible; reveal sweeps
left→right in sync with playback) — this is the human-gated visual check the sim
can't fully cover. **CI-safe frame test** via `AVAssetImageGenerator` **over the
exported `.mp4`** (not the composition) with `requestedTimeToleranceBefore/After =
.zero`, sampling `t=0`, a midpoint, and `t = duration − frameDuration`: assert
frames **non-black**, the card ROI **stable**, and bright-waveform coverage
**monotonically increases** (Codex #7, workflow #10). Reword acceptance so "the video
integration test" = these structural/content assertions, not a brittle 2-frame diff.

> ### S2 findings (2026-07-30)
>
> **The reveal is verifiably in sync.** The CI test decodes the exported `.mp4` at
> t=0 / 25% / 50% / 75% / duration−frameDuration with zero tolerance; lit coverage
> of the waveform region runs **0.02 → 0.14 → 0.31 → 0.45 → 0.62** (monotonic, wide
> margins) while the card ROI holds to **±0.001**. Thresholds were set from those
> measurements, not guessed, so the test asserts the real property without going
> flaky on encoder jitter.
>
> **The device harness exists and was validated on the simulator first**
> (`Soundpost/VideoSelfTest.swift`, DEBUG-only, `-runVideoSelfTest`). It renders a
> clip built to make sync **falsifiable by eye** — four rising beeps at 0.4 / 1.9 /
> 3.4 / 5.1 s of a 6 s clip, so the waveform shows four separated peaks and the
> playhead must cross each one exactly as it sounds — then plays the result back and
> writes an `AudioSelfTest`-shaped JSON verdict. Sim run: **PASS, drift 0.0000 s**,
> H.264 1080×1920, 180 frames.
>
> **Frames were inspected, not just measured.** Rendering on the sim and looking at
> decoded frames confirmed: card upright (glyph/date top, mark bottom), note legible,
> sweep left→right, and — at t=3.0 s — the playhead exactly at 50% with the 0.4 s and
> 1.9 s peaks lit and the 3.4 s / 5.1 s peaks still dim. That is playback-position
> sync demonstrated, not asserted.
>
> **Bug found by looking (and fixed):** `ShareCardView`'s background gradient ends in
> a *translucent* tint (`tint.opacity(0.12)`) with no opaque base, so
> `ImageRenderer`'s opaque backing showed through and the bottom of the "near-white
> card" rendered **near-black** (measured luminance **0.13** vs 0.94 at the top). Its
> inks are fixed dark greys chosen for a light ground, so the duration, the place and
> the **"Made with Soundpost" mark were unreadable**. This affected **M11's image
> share too** — and every structural test was green while it was true. Fixed by
> layering the gradient over an opaque `Color.white`, with a regression test asserting
> the card is light top *and* bottom **for all seven moods**.
>
> **Measured with the real reveal** (sim, software encoder): **≈ 219 KB/s**, ≈ 3×
> the still-card figure — the moving bars and playhead cost real bitrate. Projected
> 5-minute clip **≈ 66 MB**, ≈ 70 s to render on the sim. This is the constant §4G's
> arithmetic preflight is built from (S4); the device run replaces it if it differs.

**S3 — Gate + share UI.** Free export tap → paywall directly (unchanged); Pro → a
menu ("Share as image" / "Share as video"); the testable action policy (§4E); a
"Share a video" paywall feature line. **Add regression tests** that reveal/playback/
browse/bulk-export stay **free**. **Photos purpose string** (§4H) added + translated
here if S0/device verification requires it. All new strings EN·JA·ZH-Hans. *Verify:*
free → one paywall (no image/video tease); Pro → video; sealed-not-due → no
affordance; image path intact; free-features-free regression tests green; i18n 100%.

**S4 — Progress, cancel, preflight, hardening.** Determinate progress + Cancel
(`cancelWriting()` + Task cancel + temp cleanup); the **arithmetic** size preflight +
warn (video-bitrate constant); error surfacing (`Diagnostics.notice` + alert);
`os.Logger` on the render path; memory sanity (bounded pool); VoiceOver + Dynamic
Type on the new controls + paywall line. **All new S4 strings (progress, cancel,
preflight-warn, error) localized EN·JA·ZH-Hans in the same commit** (workflow #16).
*Verify:* cancel mid-export leaves no temp files, no crash; induced failure surfaces
honestly; warning-free; **CI green**.

> ### S3–S4 findings (2026-07-30)
>
> **Gate placement, verified in the real UI.** Driven on the simulator as a free
> user: the export control renders as a *plain button*, one tap goes straight to the
> paywall, and **no image/video menu ever appears** — the no-tease rule is structural
> (two different controls) rather than a branch inside one control. The
> **sealed-not-due** capsule's locked view was also checked live: Sealed / opens-date
> / honest-limits note / Unseal, and **no export affordance at all**. The new
> "Share a video" paywall line renders correctly.
>
> **Deviation from §3's table (deliberate):** no separate video paywall `context:`
> string was added. Because the gate sits *before* the menu, a free user only ever
> meets the generic "Export & share is a Pro feature." gate, so a video-specific
> context would be dead copy in three languages. The feature line was added as
> specified.
>
> **Preflight constant, from measurement:** `measuredBytesPerSecond = 230_000`
> (S2 measured ≈219 KB/s *with* the reveal; rounded up), warning above **40 MB** ≈
> 2:54 of audio. So the free 60-second cap never warns and only long Pro clips do.
> The estimate is a **pure function of duration** — asserted as such in tests —
> because `FileManager`'s free-space keys are a Required-Reason API
> (`NSPrivacyAccessedAPICategoryDiskSpace`) we deliberately do not adopt (§1.4/§6).
> **No PrivacyInfo change; no nutrition-label change.**
>
> **Cancel is real, and tested off observed state.** The cancel test waits until the
> render *reports* ≥5% progress before cancelling, so it is genuinely mid-render
> rather than hoping a sleep was long enough; it then asserts `CancellationError` and
> that **no partial `.mp4` survives**. Stable over three consecutive runs. Progress is
> throttled to whole percents inside the exporter (≤101 callbacks for any clip
> length), so a 9 000-frame render cannot flood the main actor with one hop per frame.
> The view also cancels on `onDisappear` — a render nobody is waiting for should not
> keep burning CPU.
>
> **Memory bound made structural:** frames are vended through
> `CVPixelBufferPoolCreatePixelBufferWithAuxAttributes` with an allocation threshold
> of 6. At the ceiling it returns `nil` (not an error) and the loop waits, so the
> render slows under back pressure instead of growing.
>
> **Still human-gated:** the Pro-side UI walkthrough (menu → video → progress →
> cancel → share sheet). `simctl` has no StoreKit support and the products load real
> ASC metadata, so granting Pro on the simulator would mean making a purchase — not
> something to do unattended. Jason can cover it with **Edit Scheme → Options →
> StoreKit Configuration → `Soundpost.storekit`**, which makes purchases local and
> free, alongside the S2 device run.

> Drop order if tight: downgrade **S2**'s per-bar reveal to a single sweeping
> **playhead line** over the still card (the minimal animation). **Never drop:** S0
> (the render proof), S1 (pipeline correctness + temp lifecycle), S3 (the gate — never
> mis-gate a Pro feature), S4's cancel/cleanup/error-surfacing.

## 6. Privacy / legal delta

**No new data, no backend, no nutrition-label change.** The video is rendered on-
device and leaves only by the user's explicit share (like M11). **Two axes, kept
separate (§1.4):** (a) **Photos "Save Video"** may require the runtime
`NSPhotoLibraryAddUsageDescription` purpose string (a *permission*, not a
Required-Reason API, and not a label change) — verify + add+translate if needed
(§4H); (b) **Required-Reason APIs** — keep the size preflight **arithmetic-only**; a
free-disk-space guard would add `NSPrivacyAccessedAPICategoryDiskSpace` and must be
declared in PrivacyInfo + re-verified in the same commit if ever adopted. No new IAP
(video is the existing Pro entitlement). Re-verify PrivacyInfo + ASC label at S3/S4.

## 7. Risks & mitigations

| Risk | Sev | Mitigation |
|---|---|---|
| The whole render path is net-new & unproven on the CI sim | **High** | **S0 render-proof spike first**; choose the path against exit criteria before any build-on-top. |
| Deprecated AVFoundation APIs break the warning-free bar (iOS 26 SDK) | **High** | `AVAssetWriter`/`AVAssetReader` primary (not deprecated); async `load(.tracks/.duration)` in tests; no `AVMutableVideoComposition`/`exportAsynchronously`/`.progress`. |
| Sim can't encode H.264 / renders black | Med | S0 asserts H.264 + non-black on the sim; if it can't, sim-skip the render test + require the **device smoke test** (S2). |
| Sync drift (model `durationSeconds` ≠ track duration) | Med | Key composition + reveal + tests to the **loaded audio-track duration**; assert parity vs the source *asset* (Codex #3). |
| Card renders upside-down / cropped | Med | Explicit top-left `CGContext` (no CALayer flip); `showsWaveform:false` + fixed `lineLimit`; S2 legibility check. |
| Render time / memory / file size on 5-min clips | Med | Bounded pixel-buffer pool; render the card once + redraw only the reveal region; measure in S0; a duration cap / fps-or-scale reduction stays a **product decision after device measurement** (Codex #11). |
| Mis-gating → "charge to receive" | **High** | Creation Pro, additive, lapse-safe; gate at start only; **free-features-stay-free regression tests** (S3). |
| Temp/share leak (stale `.mp4`s, filename collision) | Med | Unique export dir from S1; retain until `completionWithItemsHandler`; clean on failure/cancel; launch scavenge. |
| Photos "Save Video" crash / review rejection (missing purpose string) | Med | Verify on device (§4H); add + translate the string before S3 ships the share UI. |
| Scope creep (formats, templates, music, micro-levers) | Med | v1 = one vertical format, one reveal; micro-levers → M14; "remove watermark" ruled out. |

## 8. Human-in-the-loop checklist (needs Jason)

- [x] **Confirmed 2026-07-29 (Jason):** **vertical 1080×1920 / 30 fps / H.264 + AAC**
  for v1 (square is OUT, §11); **`AVAssetWriter` primary** — S0 passed first try and
  did **not** override it; keep the "Made with Soundpost" mark (no paid brand-off).
  A **duration cap** is *not* needed on S0's sim measurement (5-min Pro clip ≈ 23 MB;
  see the S0 findings box in §5) — **re-check against the device measurement at S2**
  before closing this.
- [x] **Photos permission (§4H) — decided 2026-07-29 (Jason): add it in S3.**
  `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` + a translated
  `InfoPlist.xcstrings` entry (EN·JA·ZH-Hans). Grounded in a repo finding, not just
  the plan's caution: there is **no** photo-library key in the project today, so
  M11's *existing* image share already fails the share sheet's "Save Image" activity —
  iOS has required this add-only purpose string for that activity since iOS 11. An
  unneeded add-only string is harmless; a missing one is a crash. Still worth
  confirming on-device alongside the S2 smoke test.
- [ ] **On-device smoke test (S2)** is human-gated (the sim can't fully judge visual
  sync/legibility) — a real capsule exported + played back with synced animation.
- [ ] **No ASC product work** (video is the existing Pro entitlement — no new IAP).
  The 1.3.0→1.4.0→next release sequencing stays gated on review — **not** part of M13.
- [ ] Deployment target **stays iOS 17** (the `AVAssetWriter` path needs no iOS-18
  API); do **not** raise it just for the video feature.

## 9. Reuse map

| Need | Source |
|---|---|
| Video encode / mux | first-party **`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` + `AVAssetReader`** (not deprecated; iOS-17-safe) |
| Still branded card | in-repo `ShareCardView` (+ new `showsWaveform`) via `ImageRenderer`, on `@MainActor` |
| Waveform geometry | in-repo `WaveformView` math → extracted, tested **`WaveformGeometry`** |
| Audio source | in-repo `CapsuleExporter.audioFileURL` (blob → **unique** temp `.m4a`) |
| Off-main / temp-file discipline | in-repo M12 `CapsuleBulkExporter` |
| Share plumbing | in-repo `SharePayload` / `ShareSheet` (+ a `completionWithItemsHandler` for cleanup) |
| Gate + paywall | in-repo `ProGate` / `ProPaywallView` |
| Error / logging | in-repo `Diagnostics` (os.Logger + Sentry) |
| Headless self-test pattern (S0) | in-repo `AudioSelfTest` |

## 10. Acceptance criteria

1. A **Pro user** exports a capsule as a shareable **`.mp4`** — the branded card with
   its waveform revealing in **playback-position** sync with the audio.
2. **Free users** meet the one paywall **before** any image/video menu; a
   **sealed-not-due** capsule has no video affordance; no hidden fields.
3. Export runs **off the main actor** with **progress + cancel**; a unique temp dir is
   cleaned on share-completion / failure / cancel (no stale `.mp4`s).
4. **Additive + lapse-safe:** a lapsed Pro can't start a new export but keeps prior
   shared videos; nothing re-reads `isPro` mid-render or over stored content;
   **regression tests prove reveal/playback/browse/bulk-export stay free**.
5. **Standing bars:** **warning-free on Xcode 26** (no deprecated-API warnings); all
   tests green — the **CI-safe structural + content video test** (track count, H.264,
   1080×1920, duration parity, non-black, stable card ROI, monotonic reveal) plus a
   **device smoke test**; i18n EN·JA·ZH-Hans 100% every step; zero new deps; **CI
   green**; crashes symbolicated; M10 + M11 untouched.
6. **Privacy:** any Photos "Save Video" purpose string added + translated; the size
   preflight is arithmetic-only (no undeclared Required-Reason API); no nutrition-label
   change.

## 11. Out of scope / next (M14?)

- **The Core-Animation-burn-in path** (rejected in §4A) — kept only as a documented
  alternative the S0 spike may revisit.
- **More video:** square / multiple aspect ratios; templates; music / voiceover;
  batch export. A **"remove watermark" lever is ruled OUT** (§1.3) — never a second
  charge to de-brand already-paid output.
- **Pro micro-levers → M14:** *custom mood color* (genuinely lapse-safe; but couples
  to the video render — M14 must render the stored tint, never `isPro`); *custom echo
  window* (**not** lapse-safe like a rendered preference — it seeds *new* captures, so
  gate it at **capture-start** like `maxRecordingDuration`; unrelated to video).
- **WidgetKit** home-screen countdown widget (its own small milestone).
- **Swift 6 flip** — the M12 trial quantified ~7 localized edits (`docs/SWIFT6-TRIAL.md`);
  note the new non-Sendable card/layer hand-off (§4F).
- **Promo / offer + win-back codes.**

## 12. Review record (2026-06-28)

Hardened by **Codex** (11 findings) + a **4-lens Claude audit** (iOS/AVFoundation,
product/ethics, scope/risk, privacy — 24 raw → 16 synthesized). Both independently
caught the P0s folded in above: the CoreAnimationTool no-video-track + wrong-
initializer + iOS-26-deprecation problem (→ `AVAssetWriter` primary), sync-to-track-
duration, the geometry flip, the sim-black-frame/false-green test gap (→ S0 spike +
split test tiers), the Photos purpose string, the vertical-vs-square contradiction,
the temp-lifecycle timing, gate-before-menu, and cutting the unrelated micro-levers.
**Gemini 3.1 Pro / 3.6 Flash review was requested but the Gemini CLI is tier-
ineligible on this machine** (Google migrated free-tier clients to "Antigravity"); if
Jason wants a Gemini pass, paste this doc into Gemini web/Antigravity — the plan is
otherwise review-complete.
