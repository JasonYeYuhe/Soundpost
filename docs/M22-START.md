# M22 — starting point (written at the close of M21, 2026-11-08)

Not a plan: the facts an M22 plan starts from. Write `docs/M22-DEVPLAN.md` from these, grounded
again in the code and in fresh Sentry / App Store Connect / delivery-database reads.

## Decided

- **D2 (Jason, 2026-11-08): M22 builds a launcher widget and an iOS 18 Control Center control**
  in **one new widget-extension target** — the first new target since M20 §1 forbade them. A
  launcher shows no data, so it needs **no App Group**. Both open capture idle through the
  existing door: `CaptureRequests` → `NotificationCoordinator.requestCapture()` →
  `CaptureLaunchRoute` (M20 S5) — never recording headless, never in the background. Memory:
  `soundpost-m22-widget-approved`.
- A *content* widget ("Coming up", "On this day") needs an App Group and a privacy decision
  (lock-screen exposure of notes and sounds) — scope it inside M22 or leave it out, explicitly.

## Carried from M21 (docs/M21-DEVPLAN.md §13 S6 — each needs a decision or a fix)

1. **Multi-device last day.** A sibling device's sync in a far seal's last 24 hours hands the
   seal back: it cancels the server job, which is the push for *every* device, and re-plans
   only its own local reminder. Other devices get one only if they import the cleared stamp
   and sync in the background (best-effort). Option: keep the server job through the day and
   cancel only on unseal, delete or resurface — sensible once a push to a real phone has been
   witnessed (M21 S0).
2. **Around the due instant** (≈1 minute): a hand-back whose network wait crosses the due
   time re-plans with the sync's starting `now`; a sync after the due time but before the
   poller claims the job deletes it. Option: clear the stamp without cancelling when the job is
   due within ~2 minutes.
3. **Recording on a phone set up as new earns standing** before the account's "no" arrives
   (M15 §11Q design, kept by M21 §4D). Option: run the library drains only on
   `answered || seeded`, and let standing earned by recording govern display only.
4. **New phones with no consent row show no labels until they record** (M21's intended
   effect; most accounts have no row — one is written only by a deliberate toggle). Decide
   whether onboarding's listening page should write an answer.
5. Lock-screen copy reads `soundprintRaw` regardless of standing.
6. Cancels are keyed by capsule id only: a device with a stale copy can cancel a sibling's
   freshly re-sealed job. Sending the expected wall clock with the cancel would close it
   (server change → a function deploy).
7. `send-due-notifications/apns.ts:132` fails type-checking on Deno ≥ 2.9 (`body: Uint8Array`);
   CI runs those tests with `--no-check`. Fix it on the next function deploy.
8. Still owed by Jason from M21: S0's witness (a push to a phone with a token, `status =
   'sent'`); D3 (apply `0003_m21_hygiene.sql`); D5–D9.
9. `asc.py submit` cannot recover from its own half-finished run. A `submit` that fails after
   creating its review submission (M21: the age-rating 409) leaves an empty, never-submitted
   `READY_FOR_REVIEW` draft; the next `submit` tries to cancel it first and Apple answers 409
   `Resource is not in cancellable state`. M21 finished by hand (add the version to that draft,
   then `submitted: true` — §13 S6). Fix: reuse an unsubmitted draft (no `submittedDate`)
   instead of cancelling it, as an `asc_policy` decision with a test.

## Bars at the close of M21

1.11.0 (23) submitted 2026-11-09, `WAITING_FOR_REVIEW`, `releaseType MANUAL` (Apple's new
`socialMedia` age-rating question answered "no" by Jason — M21 §13 S6); 723 tests in 95 suites; CI floor 723; 0 warnings on Xcode 26.6
(CI) and 27.2 (local clean); i18n 100% across 3 catalogs; CI caches Swift packages
(`actions/cache`, keyed on Xcode and `Package.resolved`).
