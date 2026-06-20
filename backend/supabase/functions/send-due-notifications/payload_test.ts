// deno test — pins the content-free / on-device-localized payload contract.
//   deno test backend/supabase/functions/send-due-notifications/payload_test.ts

import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertPayloadIsClean,
  BANNED_PAYLOAD_SUBSTRINGS,
  buildPushPayload,
} from "./payload.ts";

const UUID = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";

Deno.test("payload is content-free: only loc-keys + capsule_id", () => {
  const p = buildPushPayload(UUID, "seal");
  assertEquals(p.capsule_id, UUID);
  assertEquals(p.aps.alert["title-loc-key"], "push.seal.title");
  assertEquals(p.aps.alert["loc-key"], "push.seal.body");
  // No literal user-facing text anywhere (localized on-device).
  // deno-lint-ignore no-explicit-any
  assertEquals((p.aps.alert as any).title, undefined);
  // deno-lint-ignore no-explicit-any
  assertEquals((p.aps.alert as any).body, undefined);
});

Deno.test("echo kind selects echo loc-keys", () => {
  const p = buildPushPayload(UUID, "echo");
  assertEquals(p.aps.alert["title-loc-key"], "push.echo.title");
});

Deno.test("assertPayloadIsClean passes a clean payload (UUID allowlisted)", () => {
  assertPayloadIsClean(buildPushPayload(UUID, "seal"), UUID);
});

Deno.test("buildPushPayload rejects a non-UUID capsule id (no content smuggling)", () => {
  assertThrows(() => buildPushPayload("note:had a bad day", "seal"));
  assertThrows(() => buildPushPayload("", "seal"));
});

Deno.test("assertPayloadIsClean throws if content ever leaks in", () => {
  // Simulate a regression where a banned field sneaks into the payload.
  const leaked = { ...buildPushPayload(UUID, "seal"), note: "had a bad day" } as never;
  assertThrows(() => assertPayloadIsClean(leaked, UUID), Error, "note");
});

Deno.test("every banned substring is actually caught", () => {
  for (const banned of BANNED_PAYLOAD_SUBSTRINGS) {
    const leaked = { ...buildPushPayload(UUID, "seal"), [banned]: "x" } as never;
    assertThrows(() => assertPayloadIsClean(leaked, UUID), Error, banned);
  }
});
