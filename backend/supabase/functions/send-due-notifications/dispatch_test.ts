// deno test — what a rejected push records about itself (M23 §4F.2).
//   deno test backend/supabase/functions/send-due-notifications/dispatch_test.ts
//
// Drives apns.ts's own dispatchToToken with a stubbed fetch, and feeds ITS outcome to
// retryLabel. A test that handed retryLabel a hand-made outcome could not see apns.ts
// drop the reason — which it did until M23 (it read the reason, then returned only
// `http_<status>` on a retry).

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { dispatchToToken } from "./apns.ts";
import { retryLabel } from "./state.ts";

const opts = {
  host: "api.push.apple.com",
  token: "0".repeat(64),
  topic: "com.soundpost.Soundpost",
  jwt: "jwt",
  collapseId: "00000000-0000-0000-0000-000000000000",
  expiration: 0,
  payloadBytes: new TextEncoder().encode("{}"),
};

async function withFetch<T>(stub: typeof fetch, body: () => Promise<T>): Promise<T> {
  const real = globalThis.fetch;
  globalThis.fetch = stub;
  try {
    return await body();
  } finally {
    globalThis.fetch = real;
  }
}

Deno.test("a rejected send records its status and APNs reason", async () => {
  const outcome = await withFetch(
    () => Promise.resolve(new Response(JSON.stringify({ reason: "InvalidProviderToken" }), { status: 403 })),
    () => dispatchToToken(opts),
  );
  assertEquals(outcome.status, "retry");
  assertEquals(retryLabel([outcome]), "dispatch_failed:http_403:InvalidProviderToken");
});

Deno.test("a network failure is labelled network", async () => {
  const outcome = await withFetch(() => Promise.reject(new TypeError("connection reset")), () => dispatchToToken(opts));
  assertEquals(retryLabel([outcome]), "dispatch_failed:network");
});

Deno.test("a rejection with no reason body still names its status", async () => {
  const outcome = await withFetch(() => Promise.resolve(new Response("", { status: 500 })), () => dispatchToToken(opts));
  assertEquals(retryLabel([outcome]), "dispatch_failed:http_500");
});

Deno.test("one label per distinct failure, content-free and bounded", () => {
  const label = retryLabel([
    { status: "retry", httpStatus: 429, error: "http_429", reason: "TooManyRequests" },
    { status: "retry", httpStatus: 429, error: "http_429", reason: "TooManyRequests" },
    { status: "prune", httpStatus: 410, error: "Unregistered" },
    { status: "retry", httpStatus: 400, error: "http_400", reason: "Bad Topic <script>" },
  ]);
  assertEquals(label, "dispatch_failed:http_429:TooManyRequests,http_400:BadTopicscript");
  const many = retryLabel(Array.from({ length: 40 }, (_, i) => ({ status: "retry" as const, httpStatus: 400 + i, reason: "X".repeat(64) })));
  assertEquals(many.length, 200);
});
