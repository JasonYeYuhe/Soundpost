// Supabase Edge Function: sync-delivery
//
// The single write endpoint the iOS app calls to manage its own delivery state:
// register-token / upsert-job / cancel-job / delete-all. Authenticated by the
// per-user CloudKit secret (§B/§G): the app presents it as the Bearer token, and
// the function trusts it as the user identity because only the user's own
// devices hold it. The function (service role) is the ONLY writer to the tables
// — RLS denies anon/authenticated — via the SECURITY DEFINER RPCs, each scoped
// to the supplied user key, so a caller can only ever affect its own rows.
//
// `verify_jwt = false` for this function (see config.toml): the userKey bearer
// IS the auth, not a Supabase JWT. A caller without a victim's high-entropy key
// cannot read, register, or cancel anything for that victim.
//
// Privacy: this endpoint never receives capsule content — only the capsule UUID,
// fire instant (wall-clock + IANA tz), and kind. No note / place / audio.
//
// Function env (auto-provided by Supabase): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
// tz-naive local wall-clock: "YYYY-MM-DDTHH:MM:SS" (optionally with fractional s).
const WALLCLOCK_RE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?$/;

// Best-effort per-user-key rate limit (KV), so a leaked/guessed key can't be
// used to hammer the backend. Fail-open if KV is unavailable.
const RATE_LIMIT_PER_MIN = 60;

function bad(reason: string, status = 400): Response {
  return new Response(JSON.stringify({ error: reason }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
function ok(extra: Record<string, unknown> = {}): Response {
  return new Response(JSON.stringify({ ok: true, ...extra }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function isValidUserKey(k: unknown): k is string {
  return typeof k === "string" && k.length >= 16 && k.length <= 256 && /^[0-9a-fA-F]+$/.test(k);
}

async function withinRateLimit(userKey: string): Promise<boolean> {
  let kv: Deno.Kv | null = null;
  try {
    kv = await Deno.openKv();
  } catch (_e) {
    return true; // no KV → fail open, don't block legitimate calls
  }
  try {
    // Best-effort fixed-window counter keyed by (userKey, minute). A plain
    // number + expireIn (not KvU64) so the window self-expires; the read-modify-
    // write can slightly undercount under concurrency, which is fine here.
    const windowKey = ["ratelimit", userKey, Math.floor(Date.now() / 60_000)];
    const current = (await kv.get<number>(windowKey)).value ?? 0;
    const next = current + 1;
    await kv.set(windowKey, next, { expireIn: 120_000 });
    return next <= RATE_LIMIT_PER_MIN;
  } catch (_e) {
    return true;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return bad("method", 405);

  // Auth = the per-user CloudKit secret, presented as the Bearer token.
  const auth = req.headers.get("authorization") ?? "";
  const userKey = auth.replace(/^Bearer\s+/i, "").trim();
  if (!isValidUserKey(userKey)) return bad("bad_user_key", 401);

  if (!(await withinRateLimit(userKey))) return bad("rate_limited", 429);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return bad("bad_json");
  }
  const action = body.action;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  switch (action) {
    case "register_token": {
      const token = body.token;
      const environment = body.environment;
      if (typeof token !== "string" || token.length < 8 || token.length > 256) return bad("bad_token");
      if (environment !== "development" && environment !== "production") return bad("bad_environment");
      const { error } = await supabase.rpc("register_device_token", {
        p_user_key: userKey,
        p_token: token,
        p_environment: environment,
        p_platform: typeof body.platform === "string" ? body.platform : "ios",
        p_bundle_id: typeof body.bundle_id === "string" ? body.bundle_id : null,
      });
      return error ? bad("register_failed", 500) : ok();
    }

    case "unregister_token": {
      const token = body.token;
      if (typeof token !== "string" || token.length < 8) return bad("bad_token");
      const { error } = await supabase.rpc("unregister_device_token", {
        p_user_key: userKey,
        p_token: token,
      });
      return error ? bad("unregister_failed", 500) : ok();
    }

    case "upsert_job": {
      const capsuleId = body.capsule_id;
      const wallClock = body.wall_clock;
      const timeZone = body.time_zone;
      // Whitelist kind so the stored value can never disagree with the poller's
      // known loc-keys (payload.ts). Unknown / unset defaults to 'seal'.
      if (body.kind !== undefined && body.kind !== "seal" && body.kind !== "echo") {
        return bad("bad_kind");
      }
      const kind = body.kind === "echo" ? "echo" : "seal";
      if (typeof capsuleId !== "string" || !UUID_RE.test(capsuleId)) return bad("bad_capsule_id");
      if (typeof wallClock !== "string" || !WALLCLOCK_RE.test(wallClock)) return bad("bad_wall_clock");
      if (typeof timeZone !== "string" || timeZone.length < 1 || timeZone.length > 64) return bad("bad_time_zone");
      const { error } = await supabase.rpc("upsert_notification_job", {
        p_user_key: userKey,
        p_capsule_id: capsuleId,
        p_kind: kind,
        p_wall_clock: wallClock.replace("T", " "),
        p_time_zone: timeZone,
      });
      return error ? bad("upsert_failed", 500) : ok();
    }

    case "cancel_job": {
      const capsuleId = body.capsule_id;
      if (typeof capsuleId !== "string" || !UUID_RE.test(capsuleId)) return bad("bad_capsule_id");
      const { error } = await supabase.rpc("cancel_notification_job", {
        p_user_key: userKey,
        p_capsule_id: capsuleId,
      });
      return error ? bad("cancel_failed", 500) : ok();
    }

    case "delete_all": {
      const { error } = await supabase.rpc("delete_user_delivery_data", { p_user_key: userKey });
      return error ? bad("delete_failed", 500) : ok();
    }

    default:
      return bad("bad_action");
  }
});
