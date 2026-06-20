// Pure payload builders for the Soundpost far-future poller.
//
// The push is a content-free SIGNAL (docs/M10-DEVPLAN.md §C): it carries ONLY
// the capsule UUID + APNs localization keys. The user-facing text is resolved
// ON-DEVICE from the app's Localizable.strings via `title-loc-key` / `loc-key`,
// so JA/ZH stay 100% localized and the server never ships prose. No capsule
// audio / note / place / mood ever traverses APNs.
//
// `assertPayloadIsClean` is the belt: it stringifies the payload and throws if
// any banned (content-bearing) substring appears — allowlisting only the
// capsule UUID. Ported from cli pulse's send-approval-push/payload.ts.

export interface APNsPayload {
  aps: {
    alert: { "title-loc-key": string; "loc-key": string };
    sound: string;
    "mutable-content": number;
  };
  // The only routing datum — a UUID, used by the app's tap → deep-link path.
  capsule_id: string;
}

// Localization keys (must exist in the app's String Catalog — added in S3).
const LOC_KEYS = {
  seal: { title: "push.seal.title", body: "push.seal.body" },
  echo: { title: "push.echo.title", body: "push.echo.body" },
} as const;

export type JobKind = keyof typeof LOC_KEYS;

const UUID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/**
 * Build the content-free, on-device-localized APNs body for a resurfacing.
 * Throws if `capsuleId` is not UUID-shaped (defends the payload against any
 * non-UUID content sneaking into the only free-form field).
 */
export function buildPushPayload(capsuleId: string, kind: JobKind = "seal"): APNsPayload {
  if (!capsuleId || !UUID_RE.test(capsuleId)) {
    throw new Error("buildPushPayload: capsule_id is not a UUID");
  }
  const keys = LOC_KEYS[kind] ?? LOC_KEYS.seal;
  return {
    aps: {
      alert: { "title-loc-key": keys.title, "loc-key": keys.body },
      sound: "default",
      "mutable-content": 0,
    },
    capsule_id: capsuleId,
  };
}

/** Substrings that MUST NOT appear anywhere in the JSON-stringified payload —
 *  every capsule-content field plus identity. Lowercased for a case-insensitive
 *  substring search. The capsule UUID is allowlisted (it's the routing datum). */
export const BANNED_PAYLOAD_SUBSTRINGS: readonly string[] = Object.freeze([
  "note",
  "place",
  "audio",
  "waveform",
  "mood",
  "transcript",
  "latitude",
  "longitude",
  "location",
  "user_key",
  "token",
]);

/**
 * Defense-in-depth: stringify and reject if any banned substring is present.
 * Allowlists the capsule UUID before scanning so a legit `capsule_id` value (or
 * the `capsule_id` key itself) never trips the check. If this throws, abort the
 * send rather than risk shipping content.
 */
export function assertPayloadIsClean(payload: APNsPayload, capsuleId: string): void {
  let json = JSON.stringify(payload).toLowerCase();
  // Remove the allowlisted UUID and its key so they can't match a banned token.
  json = json.split(capsuleId.toLowerCase()).join("");
  json = json.split("capsule_id").join("");
  for (const banned of BANNED_PAYLOAD_SUBSTRINGS) {
    if (json.includes(banned.toLowerCase())) {
      throw new Error(`assertPayloadIsClean: payload leaked banned substring '${banned}'`);
    }
  }
}
