// deno test — pins the poller's settlement state machine.
//   deno test backend/supabase/functions/send-due-notifications/state_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { backoffSeconds, decideSettlement, MAX_ATTEMPTS } from "./state.ts";

Deno.test("any 2xx settles the job as sent (one push per device via collapse-id)", () => {
  assertEquals(decideSettlement(["ok"], 0).kind, "sent");
  assertEquals(decideSettlement(["retry", "ok"], 3).kind, "sent");
  assertEquals(decideSettlement(["prune", "ok"], 0).kind, "sent");
});

Deno.test("transient failure retries with backoff, then dead-letters at the cap", () => {
  const early = decideSettlement(["retry"], 0);
  assertEquals(early.kind, "retry");
  if (early.kind === "retry") assertEquals(early.backoffSeconds, 60);

  // attempts + 1 >= MAX_ATTEMPTS dead-letters.
  assertEquals(decideSettlement(["retry"], MAX_ATTEMPTS - 1).kind, "dead_letter");
  assertEquals(decideSettlement(["retry"], MAX_ATTEMPTS).kind, "dead_letter");
});

Deno.test("no tokens, or all-pruned, never dead-letters — waits and retries", () => {
  assertEquals(decideSettlement([], 0).kind, "no_tokens");
  assertEquals(decideSettlement(["prune"], 99).kind, "no_tokens");        // huge attempts, still not dead
  assertEquals(decideSettlement(["prune", "prune"], 5).kind, "no_tokens");
});

Deno.test("backoff is exponential, capped at 1h", () => {
  assertEquals(backoffSeconds(0), 60);
  assertEquals(backoffSeconds(1), 120);
  assertEquals(backoffSeconds(2), 240);
  assertEquals(backoffSeconds(5), 1920);
  assertEquals(backoffSeconds(6), 3600);   // capped
  assertEquals(backoffSeconds(20), 3600);  // capped
});
