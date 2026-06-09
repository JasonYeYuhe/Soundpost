# Soundpost — Project Brief

> Name chosen 2026-06-09: **Soundpost** (a *soundpost* is the dowel inside a violin that
> carries the vibration — luthiers call it "the soul"; "post" also = sending a message forward
> in time). Confirmed free of exact-name collision on the US App Store; the App Store Connect
> reservation is still the final confirm. Validated by Gemini 3.1 Pro + Codex (both ranked it #1).
> Earlier working name "Soundmark" was already taken. Alternates considered: *Yonder*, *Hark*, *Soundkeep*.

An audio-first memory app: capture ten seconds of how your life *sounds* right now as a
beautiful waveform card (sound + mood + place + one line), and optionally **seal** it to
resurface to your future self.

Status: building. M1–M4 done (record → mood-tinted waveform-card gallery → playback works
in the simulator). M5 (seal & resurface) next, then M6 (i18n + polish).
Date: 2026-06-09.

---

## 1. Research

Research tools (WebSearch / WebFetch) **were available** — findings below are real, not from
memory. Each claim is tagged **[FACT]** (with source) or **[INFERENCE]** (my analysis).
Technical claims were run through an adversarial fact-check pass; corrections are folded in.

### 1a. Competitive landscape — "message to future self" / time-capsule

| App | Platform | Pricing | Gap / weakness |
|---|---|---|---|
| **FutureMe** (futureme.org) | Web, iOS, Android | Free text tier → Plus ~$9–36/yr; iOS IAP up to $99–119 lifetime | **[FACT]** The opportunity. After 2021 acquisition it paywalled a 20-yr-free ritual in late 2025 → public backlash (HN "after greed ruined it", Reddit, alt-roundups); iOS app fell to **2.8★** (127), top complaint "it's just the website in an app" (webview), crashes, can't view >~10 old letters, lost drafts. |
| **HiFutureSelf** | iOS | Free | **[FACT]** Best-rated incumbent (**4.8★**, 543) = the bar. But: entering compose mode silently *stops* delivery; no custom repeat; stale sounds; text-only. **[INFERENCE]** Utilitarian/reminder-like, not emotional — room for a warmer experience. |
| **Dear Me – Letters To Self** | iOS/iPad/Watch | Free + tips | **[FACT]** Beautiful, but delivery is a **random 30–90 day window** — can't pick a date or send years out. Apple-only, no voice. Defeats "open in 5 years". |
| **Dear: Letters to Future Me** | iOS | $3.99 once / $14.99 yr | **[FACT]** ~1 rating → delivery reliability unproven (fatal for a "arrives years later" promise). |
| **Sealed** (openwhenitstime.com) | Web | 3 free, then credits $2.99–17.99 | **[INFERENCE, vendor site]** "Ceremony" framing; auto-captures weather/song/news + AES-256. Credit model feels nickel-and-dimey; auto-capture raises privacy Qs; no independent reviews. |
| **FuturePost** | Web, iOS | Free forever | **[FACT]** Anti-FutureMe clone; but changing email = new account; no edit/delete after delivery. **[INFERENCE]** "Free forever" from a solo dev = longevity risk for a 5–10yr promise. |
| **Letter to your future** | iOS | $2.99/**mo** | **[FACT]** ZH review: "built-in ads hurt usability". **[INFERENCE]** Monthly sub is wrong for write-once/wait-years behavior. |
| **时间胶囊-寄往未来的信** | iOS (CN) | ¥6/mo, ¥35/yr | **[FACT]** Proves CN-market demand (relevant — app is bilingual); but "too many ads, complicated fees". Even offers paper-letter mailing. |

Also catalogued: Time Capsule: Message Bottle, Time Capsule is immortality ($239.99 packages, 3.0★).

**Cross-cutting gaps:** (1) pricing trust is broken category-wide; (2) delivery longevity is
unproven; (3) most are **text-first**; (4) leaders are webviews or utilitarian UIs — no warm
native craft.

### 1b. Competitive landscape — voice / sound-memory journaling

| App | Pricing | Gap re: "sound as emotional object" |
|---|---|---|
| **Murmur – Voice Diary** | $2.99/mo, $29.99/yr | **[FACT]** Audio + 5-emotion picker + date, but **no location**, calendar-list not a card. Emotion is a *pre-record* picker, not reflection on the sound. |
| **Untold – Voice Journal** | $12.99/mo | **[FACT]** AI turns speech→text; the *transcript* is the unit, audio is disposable. No waveform object, no place. |
| **Day One** | audio gated at $49.99/yr | **[FACT]** Audio is one attachment inside a text-first entry; no mood-on-audio, no waveform card. |
| **Apple Journal** | Free, built-in | **[FACT]** iOS 18 added audio, but it's garnish on a suggestion-driven text entry. Free + preinstalled = the real threat. |
| **Apple Voice Memos** | Free | **[FACT]** Waveform exists only for *trim*; no mood, no memory framing. The raw substrate, not a product. |
| **Diarly** | ~$24/yr | **[FACT]** Location yes, but audio secondary to text, transcription gated. |
| **Cappuccino** | Freemium | **[FACT]** Social + ephemeral (limited backlog unless paid); opposite of a private archive. |
| **Sound Journal: Field Recorder** | $39.99 lifetime | **[FACT]** Closest to "sound as memory" — but pairs sound with a **photo**, not mood/place; ~4 ratings. |

**Key finding [FACT]:** *No app combines sound + mood + location + waveform-card as the unit.*
Mood-on-sound exists (Murmur); location exists (Day One/Diarly); waveform-as-card exists
**nowhere** (only as edit UI). The full triad is open.

### 1c. Differentiation & emotional hook

- **Open space [INFERENCE]:** the *sound capsule* (waveform + place + mood + one line, as a
  glanceable card) has essentially **zero consumer precedent** — nearest things are a pro field
  recorder (*Field.*) and an academic prototype (Surrey *SAM*). The future-self *half* is
  crowded and price-burned; the *sound* half is wide open.
- **The model [FACT]:** *1 Second Everyday* wins by collapsing capture to seconds and rewarding
  it with a beautiful re-playable artifact (~75% of journalers quit from friction/no payoff).
  White space = **1SE's effortless-capture + delightful-payoff loop, but for sound**, fused with
  future-self delivery so the artifact also travels forward in time.
- **Sharpest hook:** *"Capture ten seconds of how your life actually sounds right now — then let
  your future self open it like a postcard from a moment you'd otherwise forget."*
- **Differentiation:** (1) **ambient sound**, not the user talking — own "the sound of your
  life", a channel no incumbent occupies; (2) the **card is the dopamine** — instant beautiful
  waveform artifact vs. an unloved file in a list; (3) **fuse present-capture with future-resurfacing** — neither category does both.
- **Risks [FACT/INFERENCE]:** future-self framing is psychologically strong (Hershfield;
  Psych Science 2017 ~20% anxiety reduction) **but saturated + price-poisoned** → don't lead with
  it; sound is "invisible/intangible" → the card UI must make it glanceable; the deepest
  competitor is the **reflex to take a photo** → capture frequency is the existential risk;
  ambient capture has **privacy/consent** exposure (other people's voices).

### 1d. Swift Student Challenge (optional)

**[FACT]** Annual; 2026 cycle ran **Feb 6–28 2026**, winners notified **Mar 26 2026** — already
**CLOSED**. It's a separate, constrained format (a sub-3-minute self-contained Swift "app
playground"), **not** a path to shipping a real App Store app; you can't submit an existing app.
**[ASSUMPTION]** 2027 likely opens ~early Feb 2027 (extrapolated). **Verdict: not relevant** to
this build; pursue separately if eligible (perk = 1-yr Developer Program membership).

### 1e. iOS technical feasibility (the hard parts) — verified

1. **Far-future local notifications [FACT, verified]** — hard system limit of **64** pending
   requests per app; beyond that the soonest 64 are kept and the rest *silently dropped*. A
   one-shot far-future `UNCalendarNotificationTrigger` is allowed (no max horizon) and consumes
   one slot until it fires. → Keep a full local datastore; register only the 64 nearest-due;
   re-register on launch / via `BGTaskScheduler`.
2. **Persistence [FACT, verified]** — pending notifications survive force-quit, **not uninstall**
   (container deleted); reboot-before-first-unlock can delay firing. → Durable local store +
   re-register on every launch. For *guaranteed multi-year* delivery a **server (APNs) is
   effectively required**; treat the push as a "fetch" signal, not the payload (APNs coalesces to
   one queued push per device and caps payload ~4KB).
3. **Offline "time-lock" [FACT, verified] — impossible.** No trusted offline clock (user can set
   the date freely); Keychain/Data Protection gate on *unlock*, never on a *date*. Any on-device
   "locked until X" is **cosmetic / honor-system**, defeatable by changing the clock. Real
   enforcement needs server-side key release. *We will not fake this.*
4. **Audio [FACT, verified]** — `AVAudioRecorder` + `AVAudioSession` category `.playAndRecord`,
   AAC mono in `.m4a`; needs `NSMicrophoneUsageDescription` + runtime
   `AVAudioApplication.requestRecordPermission` (iOS 17+); handle interruption/route-change.
   **Foreground-only** recording → no `UIBackgroundModes audio` → no App Review 2.5.4 risk.
5. **Timezone [FACT, verified — corrected]** — for `UNCalendarNotificationTrigger`, a **nil**
   `timeZone` *floats with the device* (wall-clock; fires 9am wherever you are); **setting**
   `components.timeZone` *pins* to a fixed zone. Store the IANA tz id + intended semantics per
   capsule. (The common "nil = GMT" claim applies to `Calendar.date(from:)`, not the trigger.)
6. **Storage [FACT, verified]** — ~**0.5 MB/min** at 64 kbps mono AAC; 100×5-min ≈ ~250–500 MB.
   Store in App Support with Data Protection; iOS won't auto-offload; offer cloud-only offload of
   old delivered capsules later.

**Decision-critical facts (independently confirmed):** the **64-notification cap**, the
**impossibility of offline time-lock**, and **foreground-only audio avoids review risk**. These
three shape the architecture.

**Sources (selected):** FutureMe App Store + futureme.org + evit.com.au HN writeup +
openwhenitstime alternatives; HiFutureSelf / Dear Me / Murmur / Untold / Day One / Diarly App
Store + pricing pages; 1SE (apps.apple.com/.../id587823548) + UChicago/Surrey memory research +
Frontiers 2024; Apple Developer Forums 811171 (64 limit) + 70978 (persistence) + 110044
(no trusted clock); Apple Audio Session Programming Guide; App Store Review Guidelines 2.5.4;
Apple Platform Security (Data Protection classes); developer.apple.com/swift-student-challenge.

---

## 2. Decisions (each with a one-line rationale)

- **Positioning:** *An audio-first memory app where you capture the sound of a moment as a
  beautiful waveform card — sound + mood + place + one line — and can seal it to resurface to your
  future self.*
  — Leads with the **open** sound-capsule space and treats future-delivery as a delight, not the
  crowded, price-poisoned identity.

- **MVP scope — IN:**
  - Record a short **ambient sound or voice** clip (≤60s, foreground only). — Effortless capture is the whole habit.
  - Turn it into a **capsule card**: rendered **waveform** + **mood** + optional **place** + **one-line note** + date. — The card *is* the differentiator and the payoff.
  - **Gallery** of tappable waveform cards; tap to **play back**. — Re-livable artifact = the dopamine loop.
  - Optional **"seal until date"** → local-notification resurfacing; sealed cards show a gentle locked state with **honest** copy. — Delivers the future-self surprise without faking security.
  - **Offline-first local persistence** (SwiftData), no account. — Matches privacy/offline-first principle; zero backend to run solo.
  - **i18n EN / JA / ZH-Hans from day one.** — Non-negotiable for this developer's audience.

- **MVP scope — OUT (cut hard):** server/accounts/cloud sync/APNs; **true cryptographic
  time-lock**; **guaranteed multi-year delivery**; text "letters" as the primary mode; photos/
  video; AI transcription; social/sharing feeds; Watch/iPad-tuned UI; widgets; monetization
  build. — Each is either a different (crowded) product, a server cost, or post-PMF polish.

- **Tech stack:**
  - **Min iOS 17.0.** — Unlocks SwiftData + Observation + modern audio-permission API while keeping broad device reach.
  - **Persistence: SwiftData.** — Native, zero-dependency, offline-first store that maps cleanly to the capsule model.
  - **Audio: AVAudioRecorder/AVAudioSession** (.playAndRecord, AAC mono 64 kbps), samples read for the waveform. — Simplest reliable native capture; ~0.5 MB/min; foreground-only = no review risk.
  - **Waveform: SwiftUI `Canvas`/`Path` from sampled amplitudes.** — Makes the signature visual without a dependency.
  - **Notifications: UNUserNotificationCenter** + `UNCalendarNotificationTrigger`, 64-nearest re-registration on launch. — Handles near/mid-term resurfacing honestly within the documented cap.
  - **Architecture: SwiftUI + `@Observable` (Observation) + thin services** (AudioRecorder, AudioPlayer, CapsuleStore, NotificationScheduler, LocationProvider). — Testable and solo-maintainable without a framework.
  - **i18n: String Catalogs (`.xcstrings`), EN base + JA + ZH-Hans.** — Xcode-native, no tooling.
  - **Location: CoreLocation one-shot + reverse-geocode, optional & permission-gated.** — Place adds memory salience cheaply while staying privacy-light.
  - **Dependencies: none.** — Nothing above earns a third-party dependency for MVP.

- **Name:** **Soundpost** — the violin dowel that carries the vibration ("the soul"); "post"
  also = sending a message forward. Captures both halves (sound + future delivery) in one word.
  — Confirmed free of exact-name collision on the US App Store (ASC reservation still pending);
  ranked #1 by Gemini 3.1 Pro and Codex. ASO note: "post" skews social, so the subtitle/keywords
  must carry "audio memory / voice journal / sound capsule". Alternates: Yonder, Hark, Soundkeep.

- **Monetization (hypothesis only — not built):** free tier covers capture + cards + local
  resurfacing generously; a **one-time unlock or modest annual "Pro"** sells creation richness
  (themes/longer clips/more moods/export) and *later* cloud-backed **guaranteed** delivery.
  — Never charge to *receive* a past memory; that's exactly what triggered the FutureMe revolt.

- **Honest limits (stated plainly, not faked):**
  1. The **seal is a "gentle seal" / honor system**, not security — defeatable by changing the
     device clock or inspecting storage (no offline time-lock exists on iOS).
  2. Local delivery is **best-effort**: survives force-quit, **not** uninstall; reboot can delay;
     ≤64 nearest scheduled at once. **Guaranteed multi-year delivery needs a server (out of MVP).**
  3. **No cloud backup in MVP** → deleting the app loses capsules; the app will warn users.
  4. **Ambient recording can capture others' voices** → explicit consent/privacy copy required.

---

## 3. Build Plan (staged, independently verifiable)

> Milestone 1 is the **riskiest/most foundational** piece — the core data + state machine — not
> UI. Each milestone must compile, run in the simulator, and be committed before the next.

- **M1 — Capsule domain + state machine + persistence + scheduler logic (no UI).**
  SwiftData `Capsule` model (audio file ref, waveform samples, mood, place, note, createdAt,
  `sealUntil?`, state); the lifecycle state machine (`draft → recording → captured → sealed →
  resurfaced → opened`) with legal transitions; `CapsuleStore` (CRUD); `NotificationScheduler`
  implementing the **64-nearest** re-registration. **Verify:** unit tests for transitions +
  scheduler picking the correct ≤64 triggers; create/seal/resurface capsules programmatically.

- **M2 — Audio capture/playback pipeline.** `AudioRecorder` (.playAndRecord, AAC mono 64 kbps,
  permission, interruption/route handling), `AudioPlayer`, amplitude-sample extraction for the
  waveform. **Verify:** record → file on disk → samples → playback in a tiny harness/simulator.

- **M3 — Capture flow UI.** Record screen → mood picker → optional place → one-line note →
  creates a capsule. **Verify:** end-to-end create a real capsule in the simulator.

- **M4 — Gallery + waveform card + playback UI.** Card grid (mood color + place + date + Canvas
  waveform), tap-to-open, play, sealed-state visuals + honest copy. **Verify:** browse & play in
  the simulator.

- **M5 — Seal & resurface.** Pick a future date → schedule local notification → resurface/open
  flow + notification deep-link. **Verify:** schedule a short interval, receive the notification,
  open the capsule.

- **M6 — i18n + polish.** String Catalog EN/JA/ZH-Hans, empty/permission states, storage usage
  display, dark mode, placeholder app icon. **Verify:** switch locale, every string localizes.

### Project setup (resolved)
Per the step-4 decision (option A, done for the user): a standard `Soundpost.xcodeproj` was
hand-authored using Xcode-16 **file-system-synchronized groups** (objectVersion 77), so new
source files are auto-included without editing the project file — no XcodeGen/Tuist dependency.
iOS 17, SwiftData, zero third-party deps.
