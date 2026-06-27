# M12 kickoff prompt (paste into a fresh session)

> Copy everything inside the fenced block below into a new Claude Code session at
> the Soundpost repo to start M12 development seamlessly.

```
You are implementing Milestone M12 ("Make the resurface moment land" — UX + feature polish + hardening) for the Soundpost iOS app at /Users/jason/Documents/Soundpost.

START BY READING docs/M12-DEVPLAN.md in full — it is the precise, audit-and-Codex-hardened plan; follow it exactly, and if you ever deviate, say why. Then skim docs/PROJECT.md (the product vision §1c + the honest-limits ethos §1e), docs/DEVPLAN.md (§M12, §Mx), and the code the plan cites (ContentView.swift, Views/CapsuleDetailView.swift, Views/CapsuleCard.swift, Views/SealSheet.swift, Capture/CaptureView.swift, Capture/CaptureViewModel.swift, Services/CapsuleStore.swift, Services/NotificationCoordinator.swift, Services/NotificationPlanner.swift, Services/Delivery/SealDeliveryService.swift, Audio/AudioRecorder.swift, Services/CapsuleExporter.swift, scripts/build-upload-asc.sh).

WHERE THINGS STAND: Soundpost is live at 1.1.0; 1.3.0 (build 7 — M9 iCloud durability + M10 cloud-backed delivery) is in App Review; 1.4.0 (build 8 — M11 monetization) is uploaded and VALID, with both Pro products created in App Store Connect (annual com.soundpost.Soundpost.pro.annual + lifetime com.soundpost.Soundpost.pro.lifetime, no monthly). The M10 delivery backend is live (co-located in the cli-pulse Supabase project). Do NOT touch the M10 delivery backend, the M11 Pro gating, or the in-review 1.3.0.

THE DECISION THAT SHAPES EVERYTHING: M11 made Soundpost sellable; M12 makes it FELT. The product's whole promise — seal a sound, your future self opens it like a postcard — is currently unbuilt: a resurfaced capsule opens as an ordinary detail screen, the notification is generic, and a seal can fire at 2:47 AM. The headline is to make the resurface moment LAND. EVERYTHING in M12 is FREE-TIER — the reveal, browse/search, Settings, export-your-data, notifications, the upcoming strip are all free. Pro stays exactly as M11 shipped (additive creation richness only).

HARD CONSTRAINTS (do not violate):
- Never charge to receive a memory — no paywall on the reveal, browse/search, export-your-data, notifications, the upcoming strip, seal/resurface, or playback. Pro stays additive.
- Calm, no dark patterns — the reveal is quiet, tasteful, and FULLY Reduce-Motion-skippable (a cross-fade, not melodrama); no "share to continue" gate. Settings + filters are secondary chrome, not engagement surfaces. The review prompt fires only after a genuine resurface, capped per version, never on launch/mid-capture.
- Privacy-first — no tracking/analytics (only Sentry crash). Personalized notification copy is the user's own private words shown on the lock screen, so it is gated behind a preference that DEFAULTS OFF (opt-in). Bulk export is export-YOUR-data; nothing new leaves the device.
- Offline-first, no backend churn — M10's backend is untouched; personalizing the LOCAL notification changes no privacy posture (the server push stays content-free).
- No regression / standing bars: warning-free build; ALL tests green; i18n EN/JA/ZH-Hans 100% (incl. InfoPlist.xcstrings — currently has needs_review strings, fix in S1); ZERO new third-party deps (WidgetKit/StoreKit/AVFoundation/CloudKit are first-party).
- Each step (S1→S8) compiles + passes tests + is COMMITTED before the next. End each commit message with:
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>

WATCH THE REVIEW-SURFACED TRAPS (detailed in the plan §4/§5 — these are the P0/P1 findings, do not miss them):
- Seal-hour normalization (S2): apply the 09:00-local helper at ALL write paths — CaptureViewModel.save (the real echo path, which assigns capsule.echoAt directly; setEcho is NOT used there), the seal/echo picker, AND CapsuleStore.seal/setEcho. P0: changing sealUntil/sealTimeZoneID while a seal is server-owned MUST clear serverJobSyncedAt, or the M10 reconcile never re-upserts and the Supabase job keeps firing at the old hour (NotificationPlanner skips server-owned seals; SealDeliveryService re-upserts only when serverJobSyncedAt == nil). Test a server-owned 02:47 job normalized to 09:00 re-upserting the new wall clock.
- Personalized notification toggle (S3): when personalizedNotifications changes, FORCE a full notification reconcile (remove + re-add this app's owned requests, or fold a content/privacy version bit into the scheduled request identity) — already-scheduled requests carry the old body and ContentView resyncs only on the seal/echo signature, so a stale personalized body would otherwise linger on the lock screen. Default OFF. Test ON→OFF reverts pending requests to generic.
- The reveal routing (S4): route EVERY card-tap and deep-link through ONE "open capsule" action — refresh due seals, then present the reveal for a DUE .sealed OR .resurfaced capsule (a .sealed capsule past its date is content-visible before the flip), else navigate to detail normally. Don't trigger only on .resurfaced.
- Gallery search (S6): visibility-aware — match note/place only for isContentVisible() capsules; a sealed-not-due capsule matches only non-sensitive metadata (open date/state), never its hidden words. Keep the @Query + filtering METADATA-ONLY (never fault audioData — the M9 gallery-memory rule). Test that a locked capsule's hidden note never appears in search.
- Bulk export (S7): a DEDICATED streaming export actor, NOT a loop around CapsuleExporter (which faults the whole audioData blob and is @MainActor) — one capsule at a time, release each blob before the next, manifest separately, preflight total size from durations and warn.
- Release-ops FIRST (S1): add the dSYM upload step + a minimal CI workflow BEFORE the feature work so every M12 change is symbolicated and CI-gated; fix the InfoPlist needs_review strings; CI fails on warnings and on any new/needs_review localization.

SEQUENCE: implement S1→S8 exactly as in §5. Committed core = S1–S6; S7 (Settings + export) and S8 (upcoming strip + hardening sweep) are the splittable tail. If time is tight, drop the WidgetKit widget and the Swift 6 trial first; NEVER drop S1 (dSYM/CI), S2 (seal-hour + serverJobSyncedAt), or S3's toggle-reconcile. After each step, report what you did, the test result, and the commit hash.

HUMAN-GATED — STOP and flag Jason when you reach these (you cannot do them from code):
- SENTRY_AUTH_TOKEN (+ Sentry org/project slugs) in env for the dSYM upload step (S1), mirroring how the ASC API creds live in ~/.zshrc; backfill dSYMs for already-shipped builds from their archives.
- CI secrets only if the runner needs signing — prefer a test-only CI (xcodebuild test, no signing, no secrets).
- Confirm the overridable product decisions (the plan's §8 — all easy to change): lock-screen preview DEFAULT OFF / opt-in; DEFER the WidgetKit widget (ship the in-app upcoming strip); DEFER the in-app language override; review prompt triggers on first resurface (capped 1/version); export = zip of per-capsule .m4a + manifest.json; reveal stays quiet/skippable; sequencing reveal-first, browsability-second.
- No App Store Connect product work is needed for M12 (it is all free-tier). The M11 IAP review screenshot + the 1.4.0 submission remain separate go-live tasks, gated on 1.3.0 clearing review — do NOT do them as part of M12.

Do NOT start M13 (the animated-waveform video export milestone). The plan was hardened by a multi-lens audit (4 product/UX + 2 code/engineering lenses) plus a Codex review pass; the Gemini 3.1 Pro CLI is currently ineligible. Its findings are already folded into docs/M12-DEVPLAN.md.
```
