// deno test — pins the per-token APNs host selection (the dev→prod env-mismatch
// guard, docs/M10-DEVPLAN.md §E/§F: a dev token must hit the sandbox host and a
// prod token the production host, or delivery silently fails).
//   deno test backend/supabase/functions/send-due-notifications/apns_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { apnsHostFor } from "./apns.ts";

Deno.test("production tokens use the production host", () => {
  assertEquals(apnsHostFor("production"), "api.push.apple.com");
});

Deno.test("development tokens use the sandbox host", () => {
  assertEquals(apnsHostFor("development"), "api.sandbox.push.apple.com");
});

Deno.test("anything that isn't 'production' is treated as sandbox (fail safe)", () => {
  assertEquals(apnsHostFor(""), "api.sandbox.push.apple.com");
  assertEquals(apnsHostFor("dev"), "api.sandbox.push.apple.com");
});
