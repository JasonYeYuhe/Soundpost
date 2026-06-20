// APNs token-based-auth (ES256 .p8) JWT signing + HTTP/2 dispatch.
//
// Reused BITS ONLY from cli pulse's send-approval-push (the JWT signer, the
// ~55-min JWT cache, the HTTP/2 POST, the 410 prune). The queue/claim/backoff
// state machine is net-new (see index.ts) — cli pulse is immediate-dispatch;
// Soundpost is a far-future due-time poller (docs/M10-DEVPLAN.md §E).

const APNS_JWT_TTL_MS = 55 * 60 * 1000; // APNs accepts an iat up to 60 min old.

interface CachedJWT {
  jwt: string;
  signedAt: number;
}

let _kvPromise: Promise<Deno.Kv | null> | null = null;
function getKv(): Promise<Deno.Kv | null> {
  if (_kvPromise === null) {
    _kvPromise = (async () => {
      try {
        return await Deno.openKv();
      } catch (_err) {
        return null; // No KV in this region/cold-start → re-sign per invocation.
      }
    })();
  }
  return _kvPromise;
}

/** Build (or reuse) an APNs ES256 JWT, cached ~55 min in Deno KV. The cache key
 *  is teamId+keyId (NOT the .p8 body), so a key rotation invalidates it. */
export async function buildAPNsJWT(teamId: string, keyId: string, p8Pem: string): Promise<string> {
  const kv = await getKv();
  const cacheKey = ["apns_jwt", teamId, keyId];

  if (kv !== null) {
    try {
      const cached = await kv.get<CachedJWT>(cacheKey);
      if (cached.value?.jwt && Date.now() - cached.value.signedAt < APNS_JWT_TTL_MS) {
        return cached.value.jwt;
      }
    } catch (_err) {
      // fall through and re-sign
    }
  }

  const jwt = await signAPNsJWT(teamId, keyId, p8Pem);

  if (kv !== null) {
    try {
      await kv.set(cacheKey, { jwt, signedAt: Date.now() } as CachedJWT, { expireIn: APNS_JWT_TTL_MS });
    } catch (_err) {
      // best-effort cache; ignore write failure
    }
  }
  return jwt;
}

async function signAPNsJWT(teamId: string, keyId: string, p8Pem: string): Promise<string> {
  const pemBody = p8Pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const enc = (obj: unknown) =>
    btoa(JSON.stringify(obj)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const claims = { iss: teamId, iat: Math.floor(Date.now() / 1000) };
  const signingInput = `${enc(header)}.${enc(claims)}`;

  const sigBuf = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  // SubtleCrypto ES256 output is already raw r||s — exactly what JWT wants.
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sigBuf)))
    .replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${signingInput}.${sigB64}`;
}

/** Per-token APNs host: a dev token must hit the sandbox, a prod token the
 *  production host (§F). A mismatch is the classic silent-no-delivery bug. */
export function apnsHostFor(environment: string): string {
  return environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
}

export interface DispatchOutcome {
  status: "ok" | "prune" | "retry";
  httpStatus?: number;
  error?: string; // generic, no content
}

/**
 * POST one content-free push to one device token over HTTP/2.
 *   2xx           → ok
 *   410 / 400 BadDeviceToken → prune (token permanently invalid)
 *   anything else → retry (transient)
 * apns-collapse-id = capsule UUID is the delivery-time dedup key: APNs coalesces
 * to a single notification per capsule per device.
 */
export async function dispatchToToken(opts: {
  host: string;
  token: string;
  topic: string;
  jwt: string;
  collapseId: string;
  expiration: number; // UNIX seconds; APNs retries until then across offline windows
  payloadBytes: Uint8Array;
}): Promise<DispatchOutcome> {
  let resp: Response;
  try {
    resp = await fetch(`https://${opts.host}/3/device/${opts.token}`, {
      method: "POST",
      headers: {
        "authorization": `bearer ${opts.jwt}`,
        "apns-topic": opts.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": opts.collapseId,
        "apns-expiration": String(opts.expiration),
        "content-type": "application/json",
      },
      body: opts.payloadBytes,
      // Bound each dispatch so one hung connection can't stretch the batch past
      // the job lock lease (which would let a concurrent run re-claim + double-send).
      signal: AbortSignal.timeout(10_000),
    });
  } catch (_e) {
    return { status: "retry", error: "network" };
  }

  if (resp.status >= 200 && resp.status < 300) {
    return { status: "ok", httpStatus: resp.status };
  }

  // Read the APNs `reason` to distinguish a dead token from a transient error.
  // APNs reasons are content-free (BadDeviceToken / Unregistered / TooManyRequests…).
  let reason = "";
  try {
    reason = ((await resp.json()) as { reason?: string })?.reason ?? "";
  } catch (_e) {
    reason = "";
  }

  if (resp.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
    return { status: "prune", httpStatus: resp.status, error: reason || "410" };
  }
  return { status: "retry", httpStatus: resp.status, error: `http_${resp.status}` };
}
