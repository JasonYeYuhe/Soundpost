// Auth gate for `send-due-notifications`. This function is internal-only: it is
// invoked solely by the pg_cron trigger, which presents the M10 cron secret as a
// Bearer token plus the `X-Internal-Trigger: send_due_notifications_cron` header
// (docs/M10-DEVPLAN.md §G). The cron secret is DISTINCT from the service-role
// key, so leaking/abuse of one doesn't grant the other.
//
// The comparison is timing-safe (constant-time over equal-length digests).

export const ALLOWED_TRIGGER = "send_due_notifications_cron";

export interface AuthResult {
  ok: boolean;
  reason: string; // enumerated only: no_secret | missing_auth | bad_auth | bad_trigger
}

async function sha256(s: string): Promise<Uint8Array> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return new Uint8Array(buf);
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** Verify the cron secret (timing-safe over SHA-256 digests) + trigger header. */
export async function checkCronAuth(headers: Headers, expectedSecret: string | null | undefined): Promise<AuthResult> {
  if (!expectedSecret) return { ok: false, reason: "no_secret" };

  const auth = headers.get("authorization");
  if (!auth) return { ok: false, reason: "missing_auth" };
  const token = auth.replace(/^Bearer\s+/i, "");

  const [tokenHash, secretHash] = await Promise.all([sha256(token), sha256(expectedSecret)]);
  if (!timingSafeEqual(tokenHash, secretHash)) return { ok: false, reason: "bad_auth" };

  if (headers.get("x-internal-trigger") !== ALLOWED_TRIGGER) return { ok: false, reason: "bad_trigger" };
  return { ok: true, reason: "ok" };
}
