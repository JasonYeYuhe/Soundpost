// Pure settlement logic for the due-time poller, extracted so the queue state
// machine (backoff, dead-letter, sent/no-tokens) is unit-testable without a live
// DB or APNs (docs/M10-DEVPLAN.md §E; S6 "poller idempotency + backoff harness").

export const MAX_ATTEMPTS = 6;            // dead-letter transient failures after this
export const NO_TOKEN_BACKOFF_SECONDS = 3600;

/** Per-token dispatch outcome (see apns.ts dispatchToToken). */
export type Outcome = "ok" | "prune" | "retry";

/** Exponential backoff: 1m, 2m, 4m, 8m, 16m, 32m … capped at 1h. */
export function backoffSeconds(attempts: number): number {
  return Math.min(60 * Math.pow(2, Math.max(0, attempts)), 3600);
}

export type Settlement =
  | { kind: "sent" }
  | { kind: "retry"; backoffSeconds: number }
  | { kind: "dead_letter" }
  | { kind: "no_tokens"; backoffSeconds: number };

/**
 * Decide how to settle a job from its per-token dispatch outcomes.
 *   - any 2xx           → sent (collapse-id dedupes to one notification/device)
 *   - else any transient → retry with backoff; dead-letter once attempts hit the cap
 *   - else (all pruned, or no tokens) → no_tokens: wait + retry, never dead-letter
 *     (a reinstalled-but-not-reopened user has no token yet; the job is cancelled
 *      in-app on resurface/delete/unseal if they return)
 */
export function decideSettlement(
  outcomes: Outcome[],
  attempts: number,
  maxAttempts: number = MAX_ATTEMPTS,
): Settlement {
  if (outcomes.length === 0) {
    return { kind: "no_tokens", backoffSeconds: NO_TOKEN_BACKOFF_SECONDS };
  }
  if (outcomes.includes("ok")) {
    return { kind: "sent" };
  }
  if (outcomes.includes("retry")) {
    return attempts + 1 >= maxAttempts
      ? { kind: "dead_letter" }
      : { kind: "retry", backoffSeconds: backoffSeconds(attempts) };
  }
  // Every token was pruned (all dead) and none succeeded.
  return { kind: "no_tokens", backoffSeconds: NO_TOKEN_BACKOFF_SECONDS };
}
