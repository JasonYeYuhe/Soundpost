// Supabase Edge Function: send-due-notifications
//
// The far-future due-time POLLER (NET-NEW; cli pulse is immediate-dispatch).
// Invoked once a minute by the pg_cron trigger (auth.ts gates it with the cron
// secret). Each run:
//   1. Atomically claims a batch of DUE jobs (claim_due_notification_jobs:
//      pending + backoff elapsed + (wall_clock AT TIME ZONE tz) <= now, locked
//      FOR UPDATE SKIP LOCKED so concurrent runs never double-claim).
//   2. For each job: resolve the user's device tokens, build ONE cached APNs
//      JWT, POST a content-free localized push to each token on its per-token
//      host (collapse-id = capsule UUID = the delivery-time dedup key).
//   3. Settle the job: sent on any 2xx; prune dead tokens on 410; back off +
//      dead-letter transient failures; wait-and-retry (no dead-letter) when the
//      user currently has no tokens.
//
// Privacy: logs carry only job id / capsule id / HTTP status / generic reasons.
// The payload is content-free and re-checked by assertPayloadIsClean before send.
//
// Function env (set as secrets, NEVER in the app binary):
//   APNS_TEAM_ID, APNS_KEY_ID, APNS_P8, APNS_BUNDLE_ID, CRON_SECRET
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto-provided by Supabase)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { apnsHostFor, buildAPNsJWT, dispatchToToken, type DispatchOutcome } from "./apns.ts";
import { assertPayloadIsClean, buildPushPayload, type JobKind } from "./payload.ts";
import { checkCronAuth } from "./auth.ts";
import { decideSettlement, NO_TOKEN_BACKOFF_SECONDS, type Outcome } from "./state.ts";

// Batch + lease are sized so one run's worst-case wall-clock stays well under
// the lock lease: with a 10s per-token fetch timeout (apns.ts), 50 jobs can't
// out-run a 15-min lease, so a concurrent cron run never re-claims an in-flight
// job (which would risk a double-send). For this app's scale 50/min is ample.
const BATCH_LIMIT = 50;
const LOCK_TTL_SECONDS = 900;        // a job locked longer than this is reclaimable
const SHORT_RETRY_SECONDS = 60;      // no-fault transient waits (token read / jwt)
const PUSH_EXPIRATION_SECONDS = 28 * 24 * 60 * 60; // APNs retries ~28 days

// Privacy-safe log line: job id + generic code only, never content.
function logEvt(evt: string, jobId: string, code: string): void {
  console.error(JSON.stringify({ evt, job: jobId, code }));
}

interface JobRow {
  id: string;
  user_key: string;
  capsule_id: string;
  kind: string;
  attempts: number;
}
interface TokenRow {
  token: string;
  environment: string;
  bundle_id: string | null;
}

Deno.serve(async (req) => {
  const cronSecret = Deno.env.get("CRON_SECRET");
  const auth = await checkCronAuth(req.headers, cronSecret);
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.reason }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const teamId = Deno.env.get("APNS_TEAM_ID") ?? "";
  const keyId = Deno.env.get("APNS_KEY_ID") ?? "";
  const p8 = Deno.env.get("APNS_P8") ?? "";
  const defaultTopic = Deno.env.get("APNS_BUNDLE_ID") ?? "com.soundpost.Soundpost";
  if (!teamId || !keyId || !p8) {
    return new Response(JSON.stringify({ error: "apns_unconfigured" }), { status: 500 });
  }

  // 1. Claim a batch of due jobs.
  const { data: claimed, error: claimErr } = await supabase.rpc("claim_due_notification_jobs", {
    p_limit: BATCH_LIMIT,
    p_lock_ttl_seconds: LOCK_TTL_SECONDS,
  });
  if (claimErr) {
    return new Response(JSON.stringify({ error: "claim_failed" }), { status: 500 });
  }
  const jobs = (claimed ?? []) as JobRow[];
  if (jobs.length === 0) {
    return new Response(JSON.stringify({ claimed: 0 }), { status: 200 });
  }

  // One JWT for the whole batch (cached ~55 min across invocations).
  let jwt: string;
  try {
    jwt = await buildAPNsJWT(teamId, keyId, p8);
  } catch (_e) {
    // Couldn't sign (config-level) — unlock the batch so the next run retries
    // soon; don't burn attempts or mislabel as 'no_tokens'.
    await Promise.all(jobs.map((j) =>
      supabase.rpc("mark_job_deferred", {
        p_id: j.id,
        p_error: "jwt_unavailable",
        p_next_attempt: new Date(Date.now() + SHORT_RETRY_SECONDS * 1000).toISOString(),
      })
    ));
    return new Response(JSON.stringify({ error: "jwt_failed" }), { status: 500 });
  }

  let sent = 0, prunedTokens = 0, retried = 0, deadLettered = 0, noTokens = 0;

  for (const job of jobs) {
    // Resolve the user's tokens.
    const { data: rawTokens, error: tokenErr } = await supabase
      .from("device_tokens")
      .select("token, environment, bundle_id")
      .eq("user_key", job.user_key);
    if (tokenErr) {
      // Transient DB read error — do NOT misclassify as no-tokens (1h backoff);
      // retry next minute without burning an attempt.
      logEvt("token_read_error", job.id, tokenErr.code ?? "unknown");
      await supabase.rpc("mark_job_deferred", {
        p_id: job.id,
        p_error: "token_read_error",
        p_next_attempt: new Date(Date.now() + SHORT_RETRY_SECONDS * 1000).toISOString(),
      });
      continue;
    }
    const tokens = (rawTokens ?? []) as TokenRow[];

    if (tokens.length === 0) {
      await supabase.rpc("mark_job_deferred", {
        p_id: job.id,
        p_error: "no_tokens",
        p_next_attempt: new Date(Date.now() + NO_TOKEN_BACKOFF_SECONDS * 1000).toISOString(),
      });
      noTokens++;
      continue;
    }

    // Build + privacy-check the content-free payload once per job.
    let payloadBytes: Uint8Array;
    try {
      const payload = buildPushPayload(job.capsule_id, (job.kind as JobKind) ?? "seal");
      assertPayloadIsClean(payload, job.capsule_id);
      payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
    } catch (_e) {
      // Malformed capsule_id should be impossible (the app validates), but if it
      // happens, dead-letter rather than loop forever.
      await supabase.rpc("mark_job_retry", {
        p_id: job.id,
        p_error: "payload_build_failed",
        p_next_attempt: new Date().toISOString(),
        p_dead_letter: true,
      });
      deadLettered++;
      continue;
    }

    const outcomes: Outcome[] = [];
    for (const t of tokens) {
      const outcome: DispatchOutcome = await dispatchToToken({
        host: apnsHostFor(t.environment),
        token: t.token,
        topic: t.bundle_id || defaultTopic,
        jwt,
        collapseId: job.capsule_id,
        expiration: Math.floor(Date.now() / 1000) + PUSH_EXPIRATION_SECONDS,
        payloadBytes,
      });
      if (outcome.status === "prune") {
        const { error } = await supabase.rpc("prune_device_token", { p_token: t.token });
        if (error) logEvt("prune_failed", job.id, error.code ?? "unknown");
        else prunedTokens++;
      }
      outcomes.push(outcome.status);
    }

    const settlement = decideSettlement(outcomes, job.attempts);
    switch (settlement.kind) {
      case "sent": {
        // If this settle write fails, the job stays pending+locked and re-fires
        // after the lease — log it so the rare case is visible.
        const { error } = await supabase.rpc("mark_job_sent", { p_id: job.id });
        if (error) logEvt("mark_sent_failed", job.id, error.code ?? "unknown");
        else sent++;
        break;
      }
      case "retry": {
        const { error } = await supabase.rpc("mark_job_retry", {
          p_id: job.id,
          p_error: "dispatch_failed",
          p_next_attempt: new Date(Date.now() + settlement.backoffSeconds * 1000).toISOString(),
          p_dead_letter: false,
        });
        if (error) logEvt("mark_retry_failed", job.id, error.code ?? "unknown");
        else retried++;
        break;
      }
      case "dead_letter": {
        const { error } = await supabase.rpc("mark_job_retry", {
          p_id: job.id,
          p_error: "dispatch_failed",
          p_next_attempt: new Date().toISOString(),
          p_dead_letter: true,
        });
        if (error) logEvt("mark_deadletter_failed", job.id, error.code ?? "unknown");
        else deadLettered++;
        break;
      }
      case "no_tokens": {
        // Every token was pruned (all dead) and none succeeded — no live device.
        const { error } = await supabase.rpc("mark_job_deferred", {
          p_id: job.id,
          p_error: "no_tokens",
          p_next_attempt: new Date(Date.now() + settlement.backoffSeconds * 1000).toISOString(),
        });
        if (error) logEvt("mark_deferred_failed", job.id, error.code ?? "unknown");
        else noTokens++;
        break;
      }
    }
  }

  return new Response(
    JSON.stringify({ claimed: jobs.length, sent, prunedTokens, retried, deadLettered, noTokens }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
});
