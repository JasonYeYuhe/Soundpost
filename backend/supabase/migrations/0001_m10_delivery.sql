-- ============================================================
-- Soundpost M10 — Cloud-backed delivery schema (NET-NEW far-future poller)
-- Project: `soundpost` (org Kanousei, Supabase Pro). Date: 2026-06-20.
--
-- This is the durable far-future reminder backend. It is a *due-time poller*,
-- NOT cli-pulse's immediate-dispatch model — a sealed capsule's fire instant is
-- enqueued now and fired (best-effort) months/years later by a per-minute cron.
--
-- Hard design points (docs/M10-DEVPLAN.md §E/§G):
--   * Proof-of-ownership auth = a per-user secret the app holds in its M9
--     CloudKit PRIVATE DB. That secret is BOTH the `user_key` (fan-out group)
--     AND the bearer the app presents to `sync-delivery`. Only the user's own
--     devices possess it, so no caller can spoof another user's delivery.
--   * RLS denies anon/authenticated everything. Only the Edge Functions
--     (service role, which bypasses RLS) touch these tables, via the SECURITY
--     DEFINER RPCs below. The app NEVER hits the tables or RPCs directly — it
--     calls `sync-delivery`, which validates the bearer and calls the RPCs.
--   * Push is a content-free SIGNAL. No capsule audio/note/place ever lands
--     here — only the capsule UUID, fire instant, IANA tz, and kind.
--   * DST-correct firing: store `wall_clock` (no tz) + `time_zone`; the poller
--     fires when `(wall_clock AT TIME ZONE time_zone) <= now()`, so a years-out
--     seal fires at the intended wall-clock even if tz law changes.
--   * Idempotent upsert that NEVER resurrects a 'sent' job: the reconcile upsert
--     re-arms (status->pending) ONLY when the fire instant actually changed.
--
-- Idempotent: safe to re-run.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;   -- gen_random_uuid

-- ── 1. device_tokens ────────────────────────────────────────
-- One row per (device install). `token` is globally unique (APNs issues tokens
-- at the device+bundle+environment level), so `ON CONFLICT(token)` transfers
-- ownership atomically when a different user signs into the same iPhone — the
-- previous user's pending pushes stop going to someone else's phone.
create table if not exists public.device_tokens (
  token        text primary key,
  user_key     text not null,
  environment  text not null check (environment in ('development', 'production')),
  platform     text not null default 'ios',
  bundle_id    text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists idx_device_tokens_user_key on public.device_tokens(user_key);

alter table public.device_tokens enable row level security;
-- No policies => only the service role (Edge Functions) can read/write. Anon and
-- authenticated are denied everything. The app reaches this only via sync-delivery.

-- ── 2. notification_jobs ────────────────────────────────────
-- The far-future queue. unique(user_key, capsule_id): exactly one job per
-- capsule per user, so the reconcile upsert is a clean update-or-insert and a
-- capsule can never enqueue two competing pushes.
create table if not exists public.notification_jobs (
  id              uuid primary key default extensions.gen_random_uuid(),
  user_key        text not null,
  capsule_id      text not null,
  kind            text not null default 'seal',
  wall_clock      timestamp without time zone not null,   -- intended LOCAL fire time
  time_zone       text not null,                          -- IANA id, e.g. 'Asia/Tokyo'
  status          text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  attempts        integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  last_error      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_key, capsule_id)
);

-- Drain index: the poller scans pending, due-by-next-attempt rows.
create index if not exists idx_notification_jobs_due
  on public.notification_jobs (next_attempt_at)
  where status = 'pending';

alter table public.notification_jobs enable row level security;
-- No policies => service-role only, same as device_tokens.

-- ── 2b. delivery_optouts (server-side "Delete my cloud data" tombstone) ──
-- Account-scoped, so the deletion STICKS across all the user's devices (a
-- per-device client flag can't — clearing serverJobSyncedAt mirrors via M9
-- CloudKit and a sibling device would otherwise re-upsert, §S5/§6). While a
-- user_key is tombstoned, register_device_token + upsert_notification_job no-op
-- (raise), so a sibling device's re-upsert fails and it keeps the LOCAL backstop
-- (the client reverts serverJobSyncedAt on a failed upsert). Re-enabling delivery
-- (deleting the tombstone) is a future opt-in surface (M11/M12).
create table if not exists public.delivery_optouts (
  user_key   text primary key,
  created_at timestamptz not null default now()
);
alter table public.delivery_optouts enable row level security; -- service-role only

-- Defense-in-depth: revoke the default table-level grants so anon/authenticated
-- can't even introspect these tables (RLS already returns zero rows). The service
-- role + the SECURITY DEFINER RPCs are unaffected. (Clears advisor 0026/0027.)
revoke all on public.device_tokens    from anon, authenticated;
revoke all on public.notification_jobs from anon, authenticated;
revoke all on public.delivery_optouts  from anon, authenticated;

-- ── 3. App-facing RPCs (called by sync-delivery, service role only) ──
-- All keyed on the app-supplied `p_user_key` (the CloudKit secret / bearer).
-- SECURITY DEFINER + revoked from anon/authenticated: only the service role
-- (the Edge Function) may call them.

-- Register or transfer-ownership of a device token under a user key.
create or replace function public.register_device_token(
  p_user_key    text,
  p_token       text,
  p_environment text,
  p_platform    text,
  p_bundle_id   text
) returns void as $$
begin
  if p_user_key is null or length(p_user_key) < 16 or length(p_user_key) > 256 then
    raise exception 'invalid user_key';
  end if;
  if p_token is null or length(p_token) < 8 or length(p_token) > 256 then
    raise exception 'invalid token';
  end if;
  if p_environment not in ('development', 'production') then
    raise exception 'invalid environment';
  end if;
  if exists (select 1 from public.delivery_optouts where user_key = p_user_key) then
    raise exception 'opted_out';   -- user deleted their cloud data (§S5)
  end if;

  insert into public.device_tokens (token, user_key, environment, platform, bundle_id)
  values (p_token, p_user_key, p_environment, coalesce(p_platform, 'ios'), p_bundle_id)
  on conflict (token) do update
    set user_key    = excluded.user_key,
        environment = excluded.environment,
        platform    = excluded.platform,
        bundle_id   = excluded.bundle_id,
        updated_at  = now();
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Delete a single device token owned by this user (sign-out). User-scoped jobs
-- are deliberately NOT touched here.
create or replace function public.unregister_device_token(
  p_user_key text,
  p_token    text
) returns void as $$
begin
  delete from public.device_tokens
  where token = p_token and user_key = p_user_key;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Idempotent job upsert. Re-arms (status->pending, attempts->0, unlock) ONLY
-- when the fire instant (wall_clock or time_zone) actually changed — so a
-- launch-time re-upsert with an unchanged date NEVER resurrects a 'sent' row.
create or replace function public.upsert_notification_job(
  p_user_key   text,
  p_capsule_id text,
  p_kind       text,
  p_wall_clock timestamp without time zone,
  p_time_zone  text
) returns void as $$
begin
  if p_user_key is null or length(p_user_key) < 16 then
    raise exception 'invalid user_key';
  end if;
  if p_capsule_id is null or length(p_capsule_id) < 1 then
    raise exception 'invalid capsule_id';
  end if;
  -- Reject any non-IANA zone at the door. A bogus zone would otherwise make
  -- `wall_clock AT TIME ZONE time_zone` throw inside the batch claim and wedge
  -- delivery for ALL users (head-of-line block) — so validate before persisting.
  if p_time_zone is null or not exists (select 1 from pg_timezone_names where name = p_time_zone) then
    raise exception 'invalid time_zone';
  end if;
  if exists (select 1 from public.delivery_optouts where user_key = p_user_key) then
    raise exception 'opted_out';   -- user deleted their cloud data (§S5)
  end if;

  insert into public.notification_jobs
    (user_key, capsule_id, kind, wall_clock, time_zone, status, attempts, next_attempt_at, locked_at)
  values
    (p_user_key, p_capsule_id, coalesce(p_kind, 'seal'), p_wall_clock, p_time_zone, 'pending', 0, now(), null)
  on conflict (user_key, capsule_id) do update set
    kind       = excluded.kind,
    wall_clock = excluded.wall_clock,
    time_zone  = excluded.time_zone,
    updated_at = now(),
    status = case
      when notification_jobs.wall_clock is distinct from excluded.wall_clock
        or notification_jobs.time_zone  is distinct from excluded.time_zone
      then 'pending' else notification_jobs.status end,
    attempts = case
      when notification_jobs.wall_clock is distinct from excluded.wall_clock
        or notification_jobs.time_zone  is distinct from excluded.time_zone
      then 0 else notification_jobs.attempts end,
    next_attempt_at = case
      when notification_jobs.wall_clock is distinct from excluded.wall_clock
        or notification_jobs.time_zone  is distinct from excluded.time_zone
      then now() else notification_jobs.next_attempt_at end,
    last_error = case
      when notification_jobs.wall_clock is distinct from excluded.wall_clock
        or notification_jobs.time_zone  is distinct from excluded.time_zone
      then null else notification_jobs.last_error end,
    locked_at = case
      when notification_jobs.wall_clock is distinct from excluded.wall_clock
        or notification_jobs.time_zone  is distinct from excluded.time_zone
      then null else notification_jobs.locked_at end;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Cancel (delete) a capsule's job — on delete / unseal / resurface.
create or replace function public.cancel_notification_job(
  p_user_key   text,
  p_capsule_id text
) returns void as $$
begin
  delete from public.notification_jobs
  where user_key = p_user_key and capsule_id = p_capsule_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- "Delete my cloud data": remove every token + job for this user key AND
-- tombstone the key so a sibling device can't re-collect them (§S5/§6).
create or replace function public.delete_user_delivery_data(
  p_user_key text
) returns void as $$
begin
  insert into public.delivery_optouts (user_key) values (p_user_key)
    on conflict (user_key) do nothing;
  delete from public.notification_jobs where user_key = p_user_key;
  delete from public.device_tokens   where user_key = p_user_key;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── 4. Poller RPC: atomic claim-and-lock of due jobs ────────
-- Throw-proof due test: a malformed `time_zone` would make `AT TIME ZONE` raise,
-- and since the claim scans the whole pending set in one statement, that would
-- wedge delivery for EVERY user. This helper catches per-row so one bad row is
-- skipped (treated as not-due) instead of aborting the batch. STABLE (reads now()).
create or replace function public.is_job_due(p_wall_clock timestamp without time zone, p_time_zone text)
returns boolean as $$
begin
  return (p_wall_clock at time zone p_time_zone) <= now();
exception when others then
  return false;
end;
$$ language plpgsql stable set search_path = pg_catalog, public, extensions;

-- One UPDATE over a FOR UPDATE SKIP LOCKED subselect, so concurrent cron runs
-- never claim the same row (no double-send). "Due" = pending, its backoff has
-- elapsed, its wall-clock-in-tz has passed, and it isn't currently locked by a
-- still-running sibling (locks older than p_lock_ttl_seconds are reclaimed).
create or replace function public.claim_due_notification_jobs(
  p_limit           integer,
  p_lock_ttl_seconds integer
) returns setof public.notification_jobs as $$
  update public.notification_jobs j
  set locked_at = now()
  where j.id in (
    select id from public.notification_jobs
    where status = 'pending'
      and next_attempt_at <= now()
      and public.is_job_due(wall_clock, time_zone)
      and (locked_at is null or locked_at < now() - make_interval(secs => p_lock_ttl_seconds))
    order by next_attempt_at
    limit greatest(p_limit, 0)
    for update skip locked
  )
  returning j.*;
$$ language sql security definer set search_path = pg_catalog, public, extensions;

-- Mark a successfully-delivered job.
create or replace function public.mark_job_sent(p_id uuid) returns void as $$
begin
  update public.notification_jobs
  set status = 'sent', locked_at = null, last_error = null, updated_at = now()
  where id = p_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Record a transient failure: back off, unlock, dead-letter after the cap.
create or replace function public.mark_job_retry(
  p_id            uuid,
  p_error         text,
  p_next_attempt  timestamptz,
  p_dead_letter   boolean
) returns void as $$
begin
  update public.notification_jobs
  set attempts        = attempts + 1,
      status          = case when p_dead_letter then 'failed' else 'pending' end,
      next_attempt_at = p_next_attempt,
      locked_at       = null,
      last_error      = left(p_error, 200),
      updated_at      = now()
  where id = p_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Defer a job WITHOUT burning an attempt or dead-lettering: used for no-fault
-- waits — no registered device yet (reinstalled-not-reopened), a transient
-- token-read error, or APNs JWT not yet configured. Just unlock + reschedule,
-- recording a distinct `p_error` label so the cause is greppable. The job is
-- cancelled anyway on resurface/delete/unseal if the user returns in-app.
create or replace function public.mark_job_deferred(
  p_id           uuid,
  p_error        text,
  p_next_attempt timestamptz
) returns void as $$
begin
  update public.notification_jobs
  set next_attempt_at = p_next_attempt,
      locked_at       = null,
      last_error      = left(p_error, 200),
      updated_at      = now()
  where id = p_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Delete a dead device token (APNs 410 / BadDeviceToken).
create or replace function public.prune_device_token(p_token text) returns void as $$
begin
  delete from public.device_tokens where token = p_token;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Read a decrypted Vault secret by name. send-due-notifications uses this because
-- the service-role PostgREST client can't reach the `vault` schema directly (it's
-- not REST-exposed). Service-role only.
create or replace function public.read_m10_secret(p_name text) returns text as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_name;
$$ language sql security definer set search_path = pg_catalog, public, vault;
revoke all on function public.read_m10_secret(text) from public, anon, authenticated;
grant execute on function public.read_m10_secret(text) to service_role;

-- Lock down every RPC: service role only (the Edge Functions). Never anon.
do $$
declare fn text;
begin
  foreach fn in array array[
    'public.register_device_token(text,text,text,text,text)',
    'public.unregister_device_token(text,text)',
    'public.upsert_notification_job(text,text,text,timestamp,text)',
    'public.cancel_notification_job(text,text)',
    'public.delete_user_delivery_data(text)',
    'public.claim_due_notification_jobs(integer,integer)',
    'public.mark_job_sent(uuid)',
    'public.mark_job_retry(uuid,text,timestamptz,boolean)',
    'public.mark_job_deferred(uuid,text,timestamptz)',
    'public.prune_device_token(text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;
end $$;
