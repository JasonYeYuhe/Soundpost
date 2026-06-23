# M11 kickoff prompt (paste into a fresh session)

> Copy everything inside the fenced block below into a new Claude Code session at
> the Soundpost repo to start M11 development seamlessly.

```
You are implementing Milestone M11 (Monetization) for the Soundpost iOS app at /Users/jason/Documents/Soundpost.

START BY READING docs/M11-DEVPLAN.md in full — it is the precise, review-hardened plan; follow it exactly, and if you ever deviate, say why. Then skim docs/PROJECT.md (the Monetization decision + the honest-limits ethos), docs/DEVPLAN.md (§M11, §D4, §M12), and the code the plan cites (Capture/CaptureViewModel.swift, Audio/AudioRecorder.swift, Views/CapsuleDetailView.swift, Views/CapsuleCard.swift, Views/WaveformView.swift, SoundpostApp.swift, ContentView.swift). Reuse sources are in the plan's §9 (StoreService: Kinen; paywall: Kinen/Stride/ColorArchive/Tetsuzukit).

WHERE THINGS STAND: Soundpost is live at 1.1.0; 1.3.0 (build 7 — M9 iCloud durability + M10 cloud-backed delivery) is in App Store review. The M10 delivery backend is live (co-located in the cli-pulse Supabase project). Do NOT touch the delivery backend or M10 code paths.

THE DECISION THAT SHAPES EVERYTHING: Pro sells creation richness (export/share, longer clips, a theme pack). It does NOT gate delivery, sealing, resurfacing, playback, or any already-created capsule. Cloud-backed delivery shipped FREE and stays free. So monetization is 100% on-device StoreKit 2 (Transaction.currentEntitlements) — NO backend, NO App Store Server Notifications, NO server-side entitlement check.

HARD CONSTRAINTS (do not violate):
- Never charge to receive a past memory — no paywall on seal/resurface/notification/playback/view.
- Lapse is harmless — a lapsed annual or any non-Pro state NEVER locks an already-created capsule (incl. a >60s clip or an applied theme), an exported file, or any due/scheduled resurfacing; gates guard only the START of a new Pro action. Test this, including after a delete+reinstall with the entitlement not yet restored.
- Lifetime + annual, NO monthly.
- Honesty — one in-context, non-nagging paywall; honest copy; no dark patterns.
- No regression: warning-free build; ALL tests green; i18n EN/JA/ZH-Hans 100%; ZERO new third-party deps (StoreKit + AVFoundation are first-party).
- Each step (S1→S6) compiles + passes tests + is COMMITTED before the next. End each commit message with:
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>

WATCH THE REVIEW-SURFACED TRAPS (detailed in the plan):
- "Longer clips" is NOT trivial: AudioRecorder.maxDuration is a `let` baked at init (make it settable + have the VM read ProGate at record-start); there is no "record past 60s" gesture (the recorder hard-stops, so the upsell is an explicit affordance); WaveformExtractor reads the whole file into one PCM buffer (a 5-min clip is tens of MB on the main actor — stream it in a bounded buffer); re-localize the hardcoded "Up to 60 seconds" hint. (§2B(b)/§4D/S3)
- Subscription-disclosure compliance (App Review 3.1.2): the annual paywall must show, inline before the buy action, the title + period length + price-per-period + that it auto-renews + that it can be cancelled; link Terms = Apple Standard EULA (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) and Privacy = the existing privacy.html; provide a discoverable Restore Purchases. (§4E)
- Pro entry point: a single toolbar item in ContentView's .topBarTrailing (beside the + button) opening a lightweight sheet (Pro status, paywall, Restore, Manage Subscription, Terms/Privacy). (§4F)
- Themes are a GLOBAL UserDefaults preference (a Theme enum via ProGate.availableThemes, applied at render in CapsuleCard) — NOT a per-capsule CloudKit field; an applied theme keeps rendering on lapse. (§2B(c)/§4D)

SEQUENCE: implement S1→S6 exactly as in §5. After each step, report what you did, the test result, and the commit hash.

HUMAN-GATED — STOP and flag Jason when you reach these (you cannot do them from code):
- Signing the Paid Applications Agreement + completing banking/tax in App Store Connect (hard prerequisite for selling any IAP).
- Creating the ASC products: subscription group "Soundpost Pro" + annual auto-renewable `com.soundpost.Soundpost.pro.annual`; non-consumable `com.soundpost.Soundpost.pro.lifetime`; pricing; localized display names + descriptions (EN/JA/ZH-Hans) for BOTH products AND the subscription group's own localized name; the IAP review screenshot.
- The "Purchases" privacy-label decision (§S5/§6).
SHIP-DORMANT OPTION (§0): the StoreKit scaffold can merge + ship in a build with the products uncreated — Product.products(for:) returns empty, the paywall is unreachable, nothing is for sale — so the code can land without the human steps above, and flipping monetization on later needs no new build. Build toward this so nothing blocks on App Store Connect.

Do NOT start M12. The plan was hardened by a multi-lens adversarial review (the Gemini 3.1 Pro MCP was offline, as during M10 planning); its findings are already folded in.
```
