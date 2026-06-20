// deno test — pins the cron auth gate (timing-safe secret + trigger header).
//   deno test backend/supabase/functions/send-due-notifications/auth_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ALLOWED_TRIGGER, checkCronAuth } from "./auth.ts";

const SECRET = "super-secret-cron-token";

function headers(auth?: string, trigger?: string): Headers {
  const h = new Headers();
  if (auth !== undefined) h.set("authorization", auth);
  if (trigger !== undefined) h.set("x-internal-trigger", trigger);
  return h;
}

Deno.test("accepts the correct secret + trigger", async () => {
  const r = await checkCronAuth(headers(`Bearer ${SECRET}`, ALLOWED_TRIGGER), SECRET);
  assertEquals(r.ok, true);
});

Deno.test("rejects a wrong secret", async () => {
  const r = await checkCronAuth(headers(`Bearer nope`, ALLOWED_TRIGGER), SECRET);
  assertEquals(r.ok, false);
  assertEquals(r.reason, "bad_auth");
});

Deno.test("rejects a missing Authorization header", async () => {
  const r = await checkCronAuth(headers(undefined, ALLOWED_TRIGGER), SECRET);
  assertEquals(r.ok, false);
  assertEquals(r.reason, "missing_auth");
});

Deno.test("rejects a wrong / missing trigger header", async () => {
  const bad = await checkCronAuth(headers(`Bearer ${SECRET}`, "forged"), SECRET);
  assertEquals(bad.ok, false);
  assertEquals(bad.reason, "bad_trigger");
  const missing = await checkCronAuth(headers(`Bearer ${SECRET}`), SECRET);
  assertEquals(missing.reason, "bad_trigger");
});

Deno.test("rejects everything when no secret is configured", async () => {
  const r = await checkCronAuth(headers(`Bearer ${SECRET}`, ALLOWED_TRIGGER), "");
  assertEquals(r.ok, false);
  assertEquals(r.reason, "no_secret");
});
