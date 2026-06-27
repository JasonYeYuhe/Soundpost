# Swift 6 strict-concurrency trial (M12 §S8 / §4H-viii)

> Documented trial, **not flipped**. Quantifies the gaps between the current
> posture and Swift 6 language mode so the eventual flip is a known, small change.

## How it was run

```
xcodebuild build -scheme Soundpost \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  SWIFT_STRICT_CONCURRENCY=complete
```

(Project stays at `SWIFT_VERSION = 5.0`; `complete` surfaces every would-be Swift 6
error as a warning without changing the shipped build.)

## Result

**BUILD SUCCEEDED.** The posture is already clean — **7** concurrency diagnostics
in our own sources (none in tests), all minor and mechanical. Sentry (SPM) is not
counted; it is a third-party dependency we don't gate on.

| # | Site | Diagnostic | Fix sketch |
|---|---|---|---|
| 1–2 | `NotificationCoordinator.sync` → `scheduler.reconcile` | sending the non-`Sendable` content closure + `self.scheduler` | mark the `content` closure `@Sendable`, or make `NotificationScheduler`/`reconcile` `@Sendable`-friendly; the closure only reads value-typed locals, so it is safe in practice |
| 3, 6 | `AudioRecorder` interruption + route observers | sending `note` into the `@MainActor` hop | the block already re-hops with `Task { @MainActor in }`; adopt the `@Sendable` observer form or pull the needed `UInt` out before the hop (the pure `shouldFinalizeFor…` helpers already isolate the parse) |
| 4 | `CloudSyncMonitor` event observer | sending `note` (the `MainActor.assumeIsolated` path) | same shape as the recorder — extract the `Event` before the isolation assertion |
| 5, 7 | `CapsuleStore.all()` / `CapsuleBulkExporter` `SortDescriptor(\.createdAt)` | `KeyPath<Capsule, Date>` not `Sendable` | a toolchain nuance (key-path literals to `Sendable` properties are being made implicitly `Sendable`); hoist the `SortDescriptor` to a `static let`, or wrap in `nonisolated(unsafe)`, until the compiler change lands |

## Verdict

No structural rework needed — the few gaps are the ones predicted in the dev plan
(the detached transaction listener, the `MainActor.assumeIsolated` observers, the
`@Sendable` closure injection). The `nonisolated(unsafe)` cleanup properties added
in S8 (the AudioRecorder observer tokens, the StoreService listener) are already
the Swift-6-blessed escape hatch for deinit cleanup. Flipping to Swift 6 is a
follow-on of ~7 localized edits, not a milestone — deferred per the plan.
