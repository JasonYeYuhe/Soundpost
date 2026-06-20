# Soundpost M10 — delivery backend (Supabase)

The server half of **cloud-backed delivery** (docs/M10-DEVPLAN.md §S2/§E/§G): a
far-future **due-time poller** that fires a sealed capsule's reminder via APNs at
its wall-clock, months/years later. **Net-new** — this is NOT cli pulse's
immediate-dispatch model; only the JWT/HTTP-2/410 *bits* are reused.

> **Honest framing:** cloud-*backed*, not guaranteed. APNs is best-effort; the
> worst case stays "the capsule resurfaces next time you open the app."

## What's here

```
supabase/
  config.toml                              # verify_jwt=false for both functions (own auth)
  migrations/
    0001_m10_delivery.sql                  # tables + RLS + RPCs (apply first)
    0002_m10_cron.sql                      # pg_cron/pg_net per-minute trigger (apply last)
  functions/
    sync-delivery/index.ts                 # app write API (register/upsert/cancel/delete)
    send-due-notifications/
      index.ts                             # the poller (cron-invoked)
      apns.ts  payload.ts  auth.ts  state.ts
      *_test.ts                            # deno tests (payload privacy, cron auth, state machine)
```

Tables (`device_tokens`, `notification_jobs`, `delivery_optouts`) are content-free:
only the capsule UUID, fire instant (`wall_clock` + IANA `time_zone`), and kind.
No note / place / audio ever reaches the server. RLS denies anon/authenticated
everything; only the Edge Functions (service role) write, via the SECURITY DEFINER
RPCs.

**"Delete my cloud data" is account-scoped + sticky:** `delete_user_delivery_data`
purges the user's tokens+jobs **and** writes a `delivery_optouts` tombstone, so
`register_device_token` / `upsert_notification_job` then no-op (raise) for that
user key — a sibling device can't re-collect what was deleted. Re-enabling
delivery (deleting the tombstone) is a future opt-in surface (M11/M12).

**Auth (proof-of-ownership, §B/§G):** the app's per-user secret lives in its M9
CloudKit **private DB** and is BOTH the `user_key` (fan-out group) AND the
**Bearer** presented to `sync-delivery`. Only the user's devices hold it, so no
caller can spoof another user. The cron → `send-due-notifications` call uses a
**separate** timing-safe secret (distinct from the service-role key).

## Run the tests (no project needed)

```bash
cd backend/supabase/functions
deno test --no-check send-due-notifications/payload_test.ts \
                     send-due-notifications/auth_test.ts \
                     send-due-notifications/state_test.ts
deno check --unstable-kv send-due-notifications/index.ts sync-delivery/index.ts
```

## Deploy (HUMAN-GATED — needs Jason; docs/M10-DEVPLAN.md §8)

These cannot be done from app code. Claude can drive steps 2–4 via the Supabase
MCP **once you've done step 1 and set the secrets in step 3**.

1. **Create the project** `soundpost` in org **Kanousei** (Supabase **Pro**,
   paid). Capture the project ref + URL + service-role key + anon key.
2. **Apply migration `0001_m10_delivery.sql`** (MCP `apply_migration`, or
   `supabase db push`). Creates the tables, RLS, and RPCs.
3. **Set function secrets** (Project Settings → Edge Functions → Secrets — NEVER
   in the app binary):
   - `APNS_TEAM_ID = KHMK6Q3L3K`
   - `APNS_KEY_ID = 2R9PCC63MF`
   - `APNS_BUNDLE_ID = com.soundpost.Soundpost`
   - `APNS_P8 =` contents of `~/Documents/secrets/AuthKey_2R9PCC63MF.p8`
     (full PEM incl. the `-----BEGIN/END PRIVATE KEY-----` lines)
   - `CRON_SECRET =` a fresh long random string (e.g. `openssl rand -hex 32`)
   - `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are auto-provided.
   Confirm the APNs key `2R9PCC63MF` is enabled for the team/bundle and that
   `apns-topic` (= `APNS_BUNDLE_ID`) matches `com.soundpost.Soundpost`.
4. **Deploy both functions** (MCP `deploy_edge_function`, or
   `supabase functions deploy sync-delivery send-due-notifications`). Both are
   `verify_jwt = false` (they do their own auth).
5. **Enable `pg_cron` + `pg_net`** (Dashboard → Database → Extensions).
6. **Set the Vault secrets** the cron trigger reads, then apply
   `0002_m10_cron.sql`:
   ```sql
   select vault.create_secret('https://<project-ref>.functions.supabase.co', 'm10_app_url');
   select vault.create_secret('<the same CRON_SECRET from step 3>',          'm10_cron_secret');
   ```
   Then apply `0002_m10_cron.sql` (schedules the per-minute poll). Up-to-60s
   delivery latency is acceptable for far-future seals.
7. **Wire the client (S3):** put the project URL + anon key into the app's
   `SupabaseDeliveryBackend` config so `DeliveryBackend.isConfigured` flips true.
   (Until then the app caches tokens and uses the local path — fully functional.)

## Verify after deploy (§S2)

- Seed a far-future job for a real dev token at a wall-clock ~2 min out; confirm
  the push fires at that wall-clock (sandbox host for a `development` token).
- A bad token returns 410 → the row is pruned from `device_tokens`.
- Two concurrent poller runs never double-send (FOR UPDATE SKIP LOCKED).
- Re-running the poller does **not** re-fire a `sent` job; a launch-time
  `upsert_job` with an unchanged `wall_clock` does **not** resurrect a `sent` row.
